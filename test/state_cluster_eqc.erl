-module(state_cluster_eqc).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_cluster.hrl").
-compile(export_all).
-define(DRIVER, dht_routing_tracker).

components() -> [
	dht_state_eqc,
	dht_routing_meta_eqc,
	dht_routing_table_eqc
].

api_spec() -> api_spec(?MODULE).

prop_cluster_correct() ->
    ?SETUP(fun() ->
        eqc_mocking:start_mocking(api_spec()),
        fun() -> ok end
    end,
    ?FORALL(MetaState, dht_routing_meta_eqc:gen_state(),
    ?FORALL(StartState, dht_state_eqc:gen_initial_state(dht_routing_meta_eqc:self(MetaState)),
    ?FORALL(Cmds, eqc_cluster:commands(?MODULE, [
    		{dht_state_eqc, StartState},
    		{dht_routing_meta_eqc, MetaState}]),
      begin
        ok = eqc_lib:reset(?DRIVER),
        ok = dht_state_eqc:reset(),
        {H,S,R} = run_commands(?MODULE, Cmds),
        pretty_commands(?MODULE, Cmds, {H,S,R},
          collect(eqc_lib:summary('Length'), length(Cmds),
          aggregate(command_names(Cmds),
            R == ok)))
      end)))).
    
        