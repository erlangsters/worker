# Worker Behavior (aka 'gen_server')

A re-implementation of the `gen_server` behavior (from the OTP framework) for
the OTPless distribution of Erlang, named `worker`.

:construction: It's a work-in-progress, use at your own risk.

Written by the Erlangsters [community](https://www.erlangsters.org/) and
released under the MIT [license](https://opensource.org/license/mit).

## Getting started

XXX: To be written.

## Using it in your project

With the **Rebar3** build system, add the following to the `rebar.config` file
of your project.

```
{deps, [
  {worker, {git, "https://github.com/erlangsters/worker.git", {tag, "master"}}}
]}.
```

If you happen to use the **Erlang.mk** build system, then add the following to
your Makefile.

```
BUILD_DEPS = worker
dep_worker = git https://github.com/erlangsters/worker master
```

In practice, you want to replace the branch "master" with a specific "tag" to
avoid breaking your project if incompatible changes are made.
