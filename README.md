# Worker Behavior (aka 'gen_server')

[![Erlangsters Repository](https://img.shields.io/badge/erlangsters-worker-%23a90432)](https://github.com/erlangsters/worker)
![Supported Erlang/OTP Versions](https://img.shields.io/badge/erlang%2Fotp-27%7C28-%23a90432)
![Current Version](https://img.shields.io/badge/version-0.0.1-%23354052)
![License](https://img.shields.io/github/license/erlangsters/worker)
[![Build Status](https://img.shields.io/github/actions/workflow/status/erlangsters/worker/workflow.yml)](https://github.com/erlangsters/worker/actions/workflows/workflow.yml)
[![Documentation Link](https://img.shields.io/badge/documentation-available-yellow)](http://erlangsters.github.io/worker/)

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
