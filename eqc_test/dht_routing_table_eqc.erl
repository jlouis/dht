-module(dht_routing_table_eqc).

-compile(export_all).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_statem.hrl").

-record(state, {}).

initial_state() ->
	#state{}.

nop() ->
	ok.
	
nop_args(_S) -> [].

prop_seq() ->
    ?SETUP(fun() ->
        ok,
        fun() -> ok end
      end,
    ?FORALL(Cmds, commands(?MODULE),
      begin
        ok = routing_table:reset(),
        {H, S, R} = run_commands(?MODULE, Cmds),
        aggregate(command_names(Cmds),
          pretty_commands(?MODULE, Cmds, {H, S, R}, R == ok))
      end)).
