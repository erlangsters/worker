# Worker Behavior (aka 'gen_server')

[![Erlangsters Repository](https://img.shields.io/badge/erlangsters-worker-%23a90432)](https://github.com/erlangsters/worker)
![Supported Erlang/OTP Versions](https://img.shields.io/badge/erlang%2Fotp-27%7C28%7C29-%23a90432)
![Current Version](https://img.shields.io/badge/version-0.0.2-%23354052)
![License](https://img.shields.io/github/license/erlangsters/worker)
[![Build Status](https://img.shields.io/github/actions/workflow/status/erlangsters/worker/build.yml)](https://github.com/erlangsters/worker/actions/workflows/build.yml)
[![Documentation Link](https://img.shields.io/badge/documentation-available-yellow)](http://erlangsters.github.io/worker/)

A re-implementation of the `gen_server` behavior (from the OTP framework) for
the OTPless distribution of Erlang, named `worker`.

:construction: It's a work-in-progress, use at your own risk.

Written by the Erlangsters [community](https://about.erlangsters.org/) and
released under the MIT [license](https://opensource.org/license/mit).

## Getting started

To use `worker` in a `rebar3` project, add it to your `rebar.config`.

```erlang
{deps, [
  {worker, {git, "https://github.com/erlangsters/worker.git", {tag, "0.0.2"}}}
]}.
```

XXX: To be written.
