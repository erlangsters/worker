%%
%% Copyright (c) 2024, Byteplug LLC.
%%
%% This source file is part of a project made by the Erlangsters community and
%% is released under the MIT license. Please refer to the LICENSE.md file that
%% can be found at the root of the project directory.
%%
%% Written by Jonathan De Wachter <jonathan.dewachter@byteplug.io>, November 2024
%%
-module(worker).

-export([spawn/3, spawn/4, spawn/5]).
-export([request/2, request/3]).
-export([notify/2]).
-export([reply/2]).

-export([get_state/1]).

-compile({no_auto_import, [spawn/4]}).

%%
%% The worker behavior.
%%
%% To be written.
%%
-type name() :: atom().
-type id() :: name() | pid().

-type timer_action() :: {timer, timeout(), Message :: term()}.
-type task_action() :: {task, Message :: term()}.
-type action() :: timer_action() | task_action().

-type request_id() :: erlang:timestamp().
-type from() :: {pid(), request_id()}.

-type spawn_return() ::
    already_spawned |
    {ok, spawner:spawn_return()} |
    {aborted, Reason :: term()} |
    timeout |
    {error, Reason :: term()}
.

-callback initialize(Args :: [term()]) ->
    {continue, State :: term()} |
    {continue, State :: term(), Action :: action()} |
    {abort, Reason :: term()}
.

-callback handle_request(Request :: term(), From :: from(), State :: term()) ->
    {reply, Response :: term(), NewState :: term()} |
    {reply, Response :: term(), NewState :: term(), Action :: action()} |
    {no_reply, NewState :: term()} |
    {no_reply, NewState :: term(), Action :: action()} |
    {stop, Reason :: term(), Response :: term(), NewState :: term()} |
    {stop, Reason :: term(), NewState :: term()}
.

-callback handle_notification(Notification :: term(), State :: term()) ->
    {continue, NewState :: term()} |
    {continue, NewState :: term(), Action :: action()} |
    {stop, Reason :: term(), State :: term()}
.

-callback handle_message(Message :: term(), State :: term()) ->
    {continue, NewState :: term()} |
    {continue, NewState :: term(), Action :: action()} |
    {stop, Reason :: term(), State :: term()}
.

-callback handle_task(Payload :: term(), State :: term()) ->
    {continue, NewState :: term()} |
    {continue, NewState :: term(), Action :: action()} |
    {stop, Reason :: term(), State :: term()}
.

-callback handle_timeout(Payload :: term(), State :: term()) ->
    {continue, NewState :: term()} |
    {continue, NewState :: term(), Action :: action()} |
    {stop, Reason :: term(), State :: term()}
.

-callback terminate(Reason :: term(), State :: term()) -> no_return().

-spec spawn(spawner:mode(), module(), [term()]) -> spawn_return().
spawn(Mode, Module, Args) ->
    spawn(Mode, no_name, Module, Args).

-spec spawn(spawner:mode(), no_name | {name, name()}, module(), [term()]) -> 
    spawn_return().
spawn(Mode, Name, Module, Args) ->
    spawn(Mode, Name, Module, Args, infinity).

-spec spawn(
    spawner:mode(), 
    no_name | {name, name()}, 
    module(), 
    [term()], 
    timeout()
) -> spawn_return().
spawn(Mode, Name, Module, Args, Timeout) ->
    Root = self(),
    Loop = fun() ->
        % We register the process (if requested).
        Return = case Name of
            no_name ->
                register_ok;
            {name, Name_} ->
                try register(Name_, self()) of
                    true ->
                        register_ok
                catch
                    error:badarg ->
                        register_not_ok
                end
        end,
        case Return of
            register_ok ->
                case Module:initialize(Args) of
                    {continue, State} ->
                        Root ! {self(), '$worker_initialized'},
                        loop(Module, State, no_action, []);
                    {continue, State, Action} ->
                        Root ! {self(), '$worker_initialized'},
                        loop(Module, State, Action, []);
                    {abort, Reason} ->
                        Root ! {self(), '$worker_aborted', Reason}
                end;
            register_not_ok ->
                Root ! {self(), '$worker_already_registered'}
        end
    end,
    Setup = fun(Pid, Monitor) ->
        receive
            {'DOWN', Monitor, process, Pid, Reason} ->
                {error, Reason};
            {Pid, '$worker_already_registered'} ->
                worker_already_registered;
            {Pid, '$worker_initialized'} ->
                ok;
            {Pid, '$worker_aborted', Reason} ->
                {abort, Reason}
        after Timeout ->
            % XXX: Fix race condition here.
            erlang:exit(Pid, kill),
            timeout
        end
    end,
    {setup, Value, Return} = spawner:setup_spawn(Mode, Loop, Setup),
    case Value of
        ok ->
            {ok, Return};
        worker_already_registered ->
            already_spawned;
        {abort, Reason} ->
            {aborted, Reason};
        timeout ->
            timeout;
        {error, Reason} ->
            {error, Reason}
    end.

-spec request(id(), term()) -> {reply, Response :: term()} | no_reply.
request(Server, Request) ->
    request(Server, Request, infinity).

-spec request(id(), term(), timeout()) -> 
    {reply, Response :: term()} | no_reply.
request(Server, Request, Timeout) ->
    RequestId = erlang:timestamp(),
    From = {self(), RequestId},

    Server ! {'$worker_request', From, Request},
    receive
        {reply, RequestId, Response} ->
            {reply, Response}
    after Timeout ->
        no_reply
    end.

-spec notify(id(), term()) -> ok.
notify(Server, Message) ->
    Server ! {'$worker_notification', Message},
    ok.

-spec reply(from(), term()) -> ok.
reply({Pid, RequestId}, Response) ->
    Pid ! {reply, RequestId, Response},
    ok.

-spec get_state(id()) -> term().
get_state(Server) ->
    Server ! {'$worker_state', self()},
    receive
        {'$worker_state', Server, State} ->
            State
    end.

loop(Module, State, {timer, Timeout, Message}, Timers) ->
    % We must create a timer that must be ignored if we receive a message
    % before it expires. We generate a unique ID in order to identify it.
    Id = erlang:timestamp(),
    erlang:send_after(Timeout, self(), {'$worker_timeout', Id, Message}),
    loop(Module, State, no_action, [Id|Timers]);
loop(Module, State, {task, Task}, Timers) ->
    % We must execute a task.
    case Module:handle_task(Task, State) of
        {continue, NewState} ->
            loop(Module, NewState, no_action, Timers);
        {continue, NewState, Action} ->
            loop(Module, NewState, Action, Timers);
        {stop, Reason, NewState} ->
            try_terminate(Module, Reason, NewState)
    end;
loop(Module, State, no_action, Timers) ->
    receive
        {'$worker_state', Pid} ->
            Pid ! {'$worker_state', self(), State},
            loop(Module, State, no_action, Timers);
        {'$worker_request', From, Request} ->
            % We clear the list of timers in order to ignore timers that are
            % currently active.
            NewTimers = [],

            case Module:handle_request(Request, From, State) of
                {reply, Reply, NewState} ->
                    ok = reply(From, Reply),
                    loop(Module, NewState, no_action, NewTimers);
                {reply, Reply, NewState, Action} ->
                    ok = reply(From, Reply),
                    loop(Module, NewState, Action, NewTimers);
                {no_reply, NewState} ->
                    loop(Module, NewState, no_action, NewTimers);
                {no_reply, NewState, Action} ->
                    loop(Module, NewState, Action, NewTimers);
                {stop, Reason, Reply, NewState} ->
                    ok = reply(From, Reply),
                    try_terminate(Module, Reason, NewState);
                {stop, Reason, NewState} ->
                    try_terminate(Module, Reason, NewState)
            end;
        {'$worker_notification', Message} ->
            % We clear the list of timers in order to ignore timers that are
            % currently active.
            NewTimers = [],

            case Module:handle_notification(Message, State) of
                {continue, NewState} ->
                    loop(Module, NewState, no_action, NewTimers);
                {continue, NewState, Action} ->
                    loop(Module, NewState, Action, NewTimers);
                {stop, Reason, NewState} ->
                    try_terminate(Module, Reason, NewState)
            end;
        {'$worker_timeout', Id, Message} ->
            % A timer has expired but we must ignore it if a message has been
            % received. If the timer ID is in the list of timers, we don't
            % ignore it.
            case lists:member(Id, Timers) of
                true ->
                    % Remove the timer ID from the list of timers.
                    NewTimers = lists:delete(Id, Timers),

                    case Module:handle_timeout(Message, State) of
                        {continue, NewState} ->
                            loop(Module, NewState, no_action, NewTimers);
                        {continue, NewState, Action} ->
                            loop(Module, NewState, Action, NewTimers);
                        {stop, Reason, NewState} ->
                            try_terminate(Module, Reason, NewState)
                    end;
                false ->
                    % Simply ignore the timer.
                    loop(Module, State, no_action, Timers)
            end;
        '$worker_stop' ->
            try_terminate(Module, normal, State);
        Message ->
            % We clear the list of timers in order to ignore timers that are
            % currently active.
            NewTimers = [],

            case Module:handle_message(Message, State) of
                {continue, NewState} ->
                    loop(Module, NewState, no_action, NewTimers);
                {continue, NewState, Action} ->
                    loop(Module, NewState, Action, NewTimers);
                {stop, Reason, NewState} ->
                    try_terminate(Module, Reason, NewState)
            end
    end.

try_terminate(Module, Reason, State) ->
    case erlang:function_exported(Module, terminate, 2) of
        true ->
            Module:terminate(Reason, State),
            ok;
        false ->
            ok
    end.
