{application, 'worker', [
	{description, "The gen_server behavior for OTPless Erlang."},
	{vsn, "0.1.0"},
	{modules, ['worker']},
	{registered, []},
	{applications, [kernel,stdlib,spawn_mode]},
	{optional_applications, []},
	{env, []}
]}.