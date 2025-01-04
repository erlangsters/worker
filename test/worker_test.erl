%%
%% Copyright (c) 2024, Byteplug LLC.
%%
%% This source file is part of a project made by the Erlangsters community and
%% is released under the MIT license. Please refer to the LICENSE.md file that
%% can be found at the root of the project directory.
%%
%% Written by Jonathan De Wachter <jonathan.dewachter@byteplug.io>, November 2024
%%
-module(worker_test).
-include_lib("eunit/include/eunit.hrl").

is_process_alive(Pid, Timeout) ->
    timer:sleep(Timeout),
    erlang:is_process_alive(Pid).

flush_messages() ->
    receive
        _ -> flush_messages()
    after 0 ->
        ok
    end.

worker_test() ->
    % A canonical test meant to verify the key features of the behavior.
    meck:new(my_worker, [non_strict]),
    meck:expect(my_worker, initialize, fun(_Args) ->
        {continue, #{
            a => true,
            b => 42,
            c => "Hello world!"
        }}
    end),
    meck:expect(my_worker, handle_request, fun(Key, _From, State) ->
        {reply, maps:get(Key, State), State}
    end),
    meck:expect(my_worker, handle_notification, fun({Pid, Key}, State) ->
        Pid ! {self(), maps:get(Key, State)},
        {continue, State}
    end),
    meck:expect(my_worker, handle_message, fun({Pid, Key}, State) ->
        Pid ! {self(), maps:get(Key, State)},
        {continue, State}
    end),

    {ok, Pid} = worker:spawn(link, my_worker, [a, b, c]),

    {reply, true} = worker:request(Pid, a),
    {reply, 42} = worker:request(Pid, b),
    {reply, "Hello world!"} = worker:request(Pid, c),

    worker:notify(Pid, {self(), a}),
    receive
        {Pid, true} -> ok
    end,

    worker:notify(Pid, {self(), b}),
    receive
        {Pid, 42} -> ok
    end,

    worker:notify(Pid, {self(), c}),
    receive
        {Pid, "Hello world!"} -> ok
    end,

    Pid ! {self(), a},
    receive
        {Pid, true} -> ok
    end,

    Pid ! {self(), b},
    receive
        {Pid, 42} -> ok
    end,

    Pid ! {self(), c},
    receive
        {Pid, "Hello world!"} -> ok
    end,

    meck:unload(my_worker),

    ok.

worker_spawn_test() ->
    meck:new(my_worker, [non_strict]),
    meck:expect(my_worker, initialize, fun([a, b]) ->
        {continue, undefined}
    end),

    % Test starting with different spawn mode.
    {ok, Pid1} = worker:spawn(link, no_name, my_worker, [a, b]),
    {links, [Link]} = process_info(Pid1, links),
    Link = self(),
    process_flag(trap_exit, true),
    erlang:exit(Pid1, kill),
    ok = receive
        {'EXIT', Pid1, killed} ->
            ok
    end,

    Parent = self(),
    {ok, {Pid2, Monitor2}} = worker:spawn(monitor, no_name, my_worker, [a, b]),
    {monitored_by, [Parent]} = process_info(Pid2, monitored_by),
    erlang:exit(Pid2, yolo),
    ok = receive
        {'DOWN', Monitor2, process, Pid2, yolo} ->
            ok
    end,

    % Test starting with a name.
    false = lists:member(foobar, registered()),
    {ok, Pid3} = worker:spawn(no_link, {name, foobar}, my_worker, [a, b]),
    undefined = worker:get_state(Pid3),
    true = lists:member(foobar, registered()),
    already_spawned = worker:spawn(no_link, {name, foobar}, my_worker, [a, b]),

    meck:unload(my_worker),

    ok.

worker_enter_loop_test() ->
    flush_messages(),

    meck:new(my_worker, [non_strict]),
    meck:expect(my_worker, handle_request, fun(number, From, a) ->
        ok = worker:reply(From, 42),
        {stop, normal, b}
    end),

    Parent = self(),
    spawn(fun() ->
        a = worker:get_state(Parent),
        {reply, 42} = worker:request(Parent, number)
    end),
    ok = worker:enter_loop(my_worker, a),

    meck:expect(my_worker, terminate, fun(normal, b) ->
        custom_ok
    end),
    spawn(fun() ->
        a = worker:get_state(Parent),
        {reply, 42} = worker:request(Parent, number)
    end),
    custom_ok = worker:enter_loop(my_worker, a),

    timer:sleep(50),

    meck:unload(my_worker),

    ok.

worker_initialize_test() ->
    Parent = self(),

    meck:new(my_worker, [non_strict]),
    meck:expect(my_worker, initialize, fun([a, b]) ->
        {continue, undefined}
    end),

    meck:expect(my_worker, initialize, fun([a, b]) ->
        {abort, a}
    end),
    {aborted, a} = worker:spawn(no_link, no_name, my_worker, [a, b]),

    meck:expect(my_worker, initialize, fun([a, b]) ->
        timer:sleep(100),
        {continue, undefined}
    end),
    timeout = worker:spawn(no_link, no_name, my_worker, [a, b], 50),

    meck:expect(my_worker, initialize, fun([a, b]) ->
        {continue, yolo, {task, oloy}}
    end),
    meck:expect(my_worker, handle_task, fun(oloy, yolo) ->
        % XXX: Without this print statement, the test sometimes fails...
        io:format(user, "abc~n", []),
        Parent ! {self(), handle_task_oloy},
        {stop, ok, yolo}
    end),
    {ok, Pid1} = worker:spawn(no_link, no_name, my_worker, [a, b]),
    ok = receive
        {Pid1, handle_task_oloy} ->
            ok
    end,
    meck:expect(my_worker, initialize, fun([a, b]) ->
        {continue, yolo, {timer, 100, oloy}}
    end),
    meck:expect(my_worker, handle_timeout, fun(oloy, yolo) ->
        Parent ! {self(), handle_timeout_oloy},
        {stop, ok, yolo}
    end),
    {ok, Pid2} = worker:spawn(no_link, no_name, my_worker, [a, b]),
    ok = receive
        {Pid2, handle_timeout_oloy} ->
            not_ok
    after 50 ->
        ok
    end,
    ok = receive
        {Pid2, handle_timeout_oloy} ->
            ok
    after 100 ->
        not_ok
    end,

    % To test the "error" cases, we cover the following scenarios.
    % - The args do not match and therefore the initialize function does not
    %   match.
    % - The initialization function does not return a valid value.
    % - The initialization throws an exception.
    % - The initialization terminate the process (exit).
    % - The initialization function is not exported.
    {error, {function_clause, _}} = worker:spawn(no_link, no_name, my_worker, [a]),

    meck:expect(my_worker, initialize, fun([a, b]) -> foobar end),
    {error, {function_clause, _}} = worker:spawn(no_link, no_name, my_worker, [a]),

    meck:expect(my_worker, initialize, fun([a, b]) -> throw(foobar) end),
    {error, {{nocatch, foobar}, _}} = worker:spawn(no_link, no_name, my_worker, [a, b]),

    meck:expect(my_worker, initialize, fun([a, b]) -> exit(foobar) end),
    {error, foobar} = worker:spawn(no_link, no_name, my_worker, [a, b]),

    meck:unload(my_worker),
    meck:new(my_worker, [non_strict]),
    {error, {undef, _}} = worker:spawn(no_link, no_name, my_worker, [a, b]),

    meck:expect(my_worker, initialize, fun([a, b]) ->
        {continue, undefined}
    end),

    meck:unload(my_worker),

    ok.

worker_handle_request_test() ->
    % Test of the handle_request/3 callback. It includes the tests of the
    % request/2 and request/3 functions, as well as the reply/2 function since
    % it's only meant to be used in pair with the handle_request/3 callback.
    Parent = self(),

    meck:new(my_worker, [non_strict]),
    meck:expect(my_worker, initialize, fun([]) ->
        {continue, a}
    end),

    % Test the callback that does a "reply" without any action.
    meck:expect(my_worker, handle_request, fun(number, _From, a) ->
        {reply, 42, b}
    end),
    {ok, Pid1} = worker:spawn(no_link, no_name, my_worker, []),
    a = worker:get_state(Pid1),
    {reply, 42} = worker:request(Pid1, number),
    b = worker:get_state(Pid1),

    erlang:exit(Pid1, kill),

    % Test the callback that does a "reply" with a timer action.
    meck:expect(my_worker, handle_request, fun(number, _From, a) ->
        {reply, 42, b, {timer, 100, yolo}}
    end),
    meck:expect(my_worker, handle_timeout, fun(yolo, b) ->
        Parent ! {self(), handle_timeout_yolo},
        {continue, c}
    end),
    {ok, Pid2} = worker:spawn(no_link, no_name, my_worker, []),
    a = worker:get_state(Pid2),
    {reply, 42} = worker:request(Pid2, number),
    b = worker:get_state(Pid2),
    ok = receive
        {Pid2, handle_timeout_yolo} ->
            not_ok
    after 50 ->
        ok
    end,
    ok = receive
        {Pid2, handle_timeout_yolo} ->
            ok
    after 100 ->
        not_ok
    end,
    c = worker:get_state(Pid2),

    erlang:exit(Pid1, kill),

    % Test the callback that does a "reply": with a task action.
    meck:expect(my_worker, handle_request, fun(number, _From, a) ->
        {reply, 42, b, {task, yolo}}
    end),

    meck:expect(my_worker, handle_task, fun(yolo, b) ->
        Parent ! {self(), handle_task_yolo},
        {continue, c}
    end),
    {ok, Pid3} = worker:spawn(no_link, no_name, my_worker, []),
    a = worker:get_state(Pid3),
    {reply, 42} = worker:request(Pid3, number),
    ok = receive
        {Pid3, handle_task_yolo} ->
            ok
    end,
    c = worker:get_state(Pid3),

    erlang:exit(Pid3, kill),

    % Test the callback that does "no reply" without any action (reply is done
    % in an external process).
    meck:expect(my_worker, handle_request, fun(number, From, a) ->
        spawn(fun() ->
            timer:sleep(100),
            worker:reply(From, 42)
        end),
        {no_reply, b}
    end),
    {ok, Pid4} = worker:spawn(no_link, no_name, my_worker, []),
    a = worker:get_state(Pid4),
    {reply, 42} = worker:request(Pid4, number),
    b = worker:get_state(Pid4),

    erlang:exit(Pid4, kill),

    % Test the callback that does "no reply" with a timer action (reply is
    % done in the timeout callback).
    meck:expect(my_worker, handle_request, fun(number, From, a) ->
        {no_reply, b, {timer, 500, {yolo, From}}}
    end),
    meck:expect(my_worker, handle_timeout, fun({yolo, From}, b) ->
        worker:reply(From, 42),
        {continue, c}
    end),
    {ok, Pid5} = worker:spawn(no_link, no_name, my_worker, []),
    a = worker:get_state(Pid5),
    {reply, 42} = worker:request(Pid5, number),
    c = worker:get_state(Pid5),

    erlang:exit(Pid5, kill),

    % Test the callback that does "no reply" with a task action (reply is done
    % in the task callback).
    meck:expect(my_worker, handle_request, fun(number, From, a) ->
        {no_reply, b, {task, {yolo, From}}}
    end),
    meck:expect(my_worker, handle_task, fun({yolo, From}, b) ->
        worker:reply(From, 42),
        {continue, c}
    end),
    {ok, Pid6} = worker:spawn(no_link, no_name, my_worker, []),
    a = worker:get_state(Pid6),
    {reply, 42} = worker:request(Pid6, number),
    c = worker:get_state(Pid6),

    erlang:exit(Pid6, kill),

    % Test the callback that stops the worker without a reply.
    meck:expect(my_worker, handle_request, fun(number, _From, a) ->
        {stop, yolo, b}
    end),
    meck:expect(my_worker, terminate, fun(yolo, b) ->
        Parent ! {self(), terminate_yolo}
    end),

    {ok, Pid8} = worker:spawn(no_link, no_name, my_worker, []),
    no_reply = worker:request(Pid8, number, 50),
    ok = receive
        {Pid8, terminate_yolo} ->
            ok
    end,

    false = is_process_alive(Pid8, 100),

    % Test the callback that stops the worker and returns a reply.
    meck:expect(my_worker, handle_request, fun(number, _From, a) ->
        {stop, yolo, 42, b}
    end),
    meck:expect(my_worker, terminate, fun(yolo, b) ->
        Parent ! {self(), terminate_yolo}
    end),

    {ok, Pid9} = worker:spawn(no_link, no_name, my_worker, []),
    {reply, 42} = worker:request(Pid9, number),
    ok = receive
        {Pid9, terminate_yolo} ->
            ok
    end,

    false = is_process_alive(Pid9, 100),

    meck:unload(my_worker),

    ok.

worker_handle_notification_test() ->
    % Test of the handle_notification/2 callback. It includes the test of the
    % notify/2 function.
    Parent = self(),

    meck:new(my_worker, [non_strict]),
    meck:expect(my_worker, initialize, fun([]) ->
        {continue, a}
    end),

    % Test the callback that does not do any action.
    meck:expect(my_worker, handle_notification, fun(number, a) ->
        Parent ! {self(), handle_notification},
        {continue, b}
    end),

    {ok, Pid1} = worker:spawn(no_link, no_name, my_worker, []),
    a = worker:get_state(Pid1),
    ok = worker:notify(Pid1, number),
    ok = receive
        {Pid1, handle_notification} ->
            ok
    end,
    b = worker:get_state(Pid1),

    erlang:exit(Pid1, kill),

    % Test the callback that returns a timer action.
    meck:expect(my_worker, handle_notification, fun(number, a) ->
        {continue, b, {timer, 100, yolo}}
    end),
    meck:expect(my_worker, handle_timeout, fun(yolo, b) ->
        Parent ! {self(), handle_timeout_yolo},
        {continue, c}
    end),
    {ok, Pid2} = worker:spawn(no_link, no_name, my_worker, []),
    a = worker:get_state(Pid2),
    ok = worker:notify(Pid2, number),
    ok = receive
        {Pid2, handle_timeout_yolo} ->
            not_ok
    after 50 ->
        ok
    end,
    ok = receive
        {Pid2, handle_timeout_yolo} ->
            ok
    after 100 ->
        not_ok
    end,
    c = worker:get_state(Pid2),

    erlang:exit(Pid2, kill),

    % Test the callback that returns a task action.
    meck:expect(my_worker, handle_notification, fun(number, a) ->
        {continue, b, {task, yolo}}
    end),

    meck:expect(my_worker, handle_task, fun(yolo, b) ->
        Parent ! {self(), handle_task_yolo},
        {continue, c}
    end),
    {ok, Pid3} = worker:spawn(no_link, no_name, my_worker, []),
    a = worker:get_state(Pid3),
    ok = worker:notify(Pid3, number),
    ok = receive
        {Pid3, handle_task_yolo} ->
            ok
    end,
    c = worker:get_state(Pid3),

    erlang:exit(Pid3, kill),

    % Test the callback that stops the worker.
    meck:expect(my_worker, handle_notification, fun(number, a) ->
        {stop, yolo, b}
    end),
    meck:expect(my_worker, terminate, fun(yolo, b) ->
        Parent ! {self(), terminate_yolo}
    end),
    {ok, Pid4} = worker:spawn(no_link, no_name, my_worker, []),
    a = worker:get_state(Pid4),
    ok = worker:notify(Pid4, number),
    ok = receive
        {Pid4, terminate_yolo} ->
            ok
    end,

    false = is_process_alive(Pid4, 100),

    meck:unload(my_worker),

    ok.

worker_handle_message_test() ->
    % Test of the handle_message/2 callback.
    Parent = self(),

    meck:new(my_worker, [non_strict]),
    meck:expect(my_worker, initialize, fun([]) ->
        {continue, a}
    end),

    % Test the callback that does no action.
    meck:expect(my_worker, handle_message, fun(number, a) ->
        Parent ! {self(), handle_message},
        {continue, b}
    end),

    {ok, Pid1} = worker:spawn(no_link, no_name, my_worker, []),
    a = worker:get_state(Pid1),
    Pid1 ! number,
    ok = receive
        {Pid1, handle_message} ->
            ok
    end,
    b = worker:get_state(Pid1),

    erlang:exit(Pid1, kill),

    % Test the callback that returns a timer action.
    meck:expect(my_worker, handle_message, fun(number, a) ->
        {continue, b, {timer, 100, yolo}}
    end),
    meck:expect(my_worker, handle_timeout, fun(yolo, b) ->
        Parent ! {self(), handle_timeout_yolo},
        {continue, c}
    end),
    {ok, Pid2} = worker:spawn(no_link, no_name, my_worker, []),
    a = worker:get_state(Pid2),
    Pid2 ! number,
    ok = receive
        {Pid2, handle_timeout_yolo} ->
            not_ok
    after 50 ->
        ok
    end,
    ok = receive
        {Pid2, handle_timeout_yolo} ->
            ok
    after 100 ->
        not_ok
    end,
    c = worker:get_state(Pid2),

    erlang:exit(Pid2, kill),

    % Test the callback that returns a task action.
    meck:expect(my_worker, handle_message, fun(number, a) ->
        {continue, b, {task, yolo}}
    end),

    meck:expect(my_worker, handle_task, fun(yolo, b) ->
        Parent ! {self(), handle_task_yolo},
        {continue, c}
    end),
    {ok, Pid3} = worker:spawn(no_link, no_name, my_worker, []),
    a = worker:get_state(Pid3),
    Pid3 ! number,
    ok = receive
        {Pid3, handle_task_yolo} ->
            ok
    end,
    c = worker:get_state(Pid3),

    erlang:exit(Pid3, kill),

    % Test the callback that stops the worker.
    meck:expect(my_worker, handle_message, fun(number, a) ->
        {stop, yolo, b}
    end),
    meck:expect(my_worker, terminate, fun(yolo, b) ->
        Parent ! {self(), terminate_yolo}
    end),
    {ok, Pid4} = worker:spawn(no_link, no_name, my_worker, []),
    a = worker:get_state(Pid4),
    Pid4 ! number,
    ok = receive
        {Pid4, terminate_yolo} ->
            ok
    end,

    false = is_process_alive(Pid4, 50),

    meck:unload(my_worker),

    ok.

worker_handle_timeout_test() ->
    % Test of the handle_timeout/2 callback.
    Parent = self(),

    meck:new(my_worker, [non_strict]),
    meck:expect(my_worker, initialize, fun([]) ->
        {continue, a}
    end),
    meck:expect(my_worker, handle_message, fun(number, a) ->
        {continue, a, {timer, 100, yolo}}
    end),

    % Test the callback that does another timer action.
    meck:expect(my_worker, handle_timeout, fun
        (yolo, a) ->
            Parent ! {self(), handle_timeout_yolo},
            {continue, b, {timer, 100, oloy}};
        (oloy, b) ->
            Parent ! {self(), handle_timeout_oloy},
            {continue, c}
    end),

    {ok, Pid1} = worker:spawn(no_link, no_name, my_worker, []),
    a = worker:get_state(Pid1),
    Pid1 ! number,
    ok = receive
        {Pid1, handle_timeout_yolo} ->
            not_ok
    after 50 ->
        ok
    end,
    ok = receive
        {Pid1, handle_timeout_yolo} ->
            ok
    after 100 ->
        not_ok
    end,
    timer:sleep(25),
    b = worker:get_state(Pid1),
    ok = receive
        {Pid1, handle_timeout_oloy} ->
            not_ok
    after 50 ->
        ok
    end,
    ok = receive
        {Pid1, handle_timeout_oloy} ->
            ok
    after 100 ->
        not_ok
    end,
    timer:sleep(25),
    c = worker:get_state(Pid1),

    erlang:exit(Pid1, kill),

    % Test the callback that does a task action.
    meck:expect(my_worker, handle_timeout, fun(yolo, a) ->
        {continue, b, {task, yolo}}
    end),
    meck:expect(my_worker, handle_task, fun(yolo, b) ->
        Parent ! {self(), handle_task_yolo},
        {continue, c}
    end),

    {ok, Pid2} = worker:spawn(no_link, no_name, my_worker, []),
    a = worker:get_state(Pid2),
    Pid2 ! number,
    ok = receive
        {Pid2, handle_task_yolo} ->
            not_ok
    after 50 ->
        ok
    end,
    ok = receive
        {Pid2, handle_task_yolo} ->
            ok
    after 100 ->
        not_ok
    end,
    timer:sleep(25),
    c = worker:get_state(Pid2),

    erlang:exit(Pid2, kill),

    % Test the callback that stops the worker.
    meck:expect(my_worker, handle_timeout, fun(yolo, a) ->
        {stop, yolo, b}
    end),
    meck:expect(my_worker, terminate, fun(yolo, b) ->
        Parent ! {self(), terminate_yolo}
    end),

    {ok, Pid3} = worker:spawn(no_link, no_name, my_worker, []),
    a = worker:get_state(Pid3),
    Pid3 ! number,
    ok = receive
        {Pid3, terminate_yolo} ->
            not_ok
    after 50 ->
        ok
    end,
    ok = receive
        {Pid3, terminate_yolo} ->
            ok
    after 100 ->
        not_ok
    end,
    false = is_process_alive(Pid3, 50),

    meck:unload(my_worker),

    ok.

worker_handle_task_test() ->
    % Test of the handle_task/2 callback.
    Parent = self(),

    meck:new(my_worker, [non_strict]),
    meck:expect(my_worker, initialize, fun([]) ->
        {continue, a}
    end),
    meck:expect(my_worker, handle_message, fun(number, a) ->
        {continue, a, {task, yolo}}
    end),

    % Test the callback that does another task action.
    meck:expect(my_worker, handle_task, fun
        (yolo, a) ->
            Parent ! {self(), handle_task_yolo},
            {continue, b, {task, oloy}};
        (oloy, b) ->
            Parent ! {self(), handle_task_oloy},
            {continue, c}
    end),

    {ok, Pid1} = worker:spawn(no_link, no_name, my_worker, []),
    a = worker:get_state(Pid1),
    Pid1 ! number,
    ok = receive
        {Pid1, handle_task_yolo} ->
            ok
    after 50 ->
        not_ok
    end,
    ok = receive
        {Pid1, handle_task_oloy} ->
            ok
    after 50 ->
        not_ok
    end,
    c = worker:get_state(Pid1),

    erlang:exit(Pid1, kill),

    % Test the callback that does a timer action.
    meck:expect(my_worker, handle_task, fun(yolo, a) ->
        {continue, b, {timer, 100, yolo}}
    end),
    meck:expect(my_worker, handle_timeout, fun(yolo, b) ->
        Parent ! {self(), handle_timeout_yolo},
        {continue, c}
    end),

    {ok, Pid2} = worker:spawn(no_link, no_name, my_worker, []),
    a = worker:get_state(Pid2),
    Pid2 ! number,
    ok = receive
        {Pid2, handle_timeout_yolo} ->
            not_ok
    after 50 ->
        ok
    end,
    ok = receive
        {Pid2, handle_timeout_yolo} ->
            ok
    after 50 ->
        not_ok
    end,
    timer:sleep(25),
    c = worker:get_state(Pid2),

    erlang:exit(Pid2, kill),

    % Test the callback that stops the worker.
    meck:expect(my_worker, handle_task, fun(yolo, a) ->
        {stop, yolo, b}
    end),
    meck:expect(my_worker, terminate, fun(yolo, b) ->
        Parent ! {self(), terminate_yolo}
    end),

    {ok, Pid3} = worker:spawn(no_link, no_name, my_worker, []),
    a = worker:get_state(Pid3),
    Pid3 ! number,
    ok = receive
        {Pid3, terminate_yolo} ->
            ok
    after 50 ->
        not_ok
    end,

    false = is_process_alive(Pid3, 50),

    meck:unload(my_worker),

    ok.
