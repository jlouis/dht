-module(routing_cluster_eqc).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_cluster.hrl").
-compile(export_all).

components() -> [
	dht_routing_meta_eqc, dht_routing_table_eqc
].

api_spec() -> api_spec(?MODULE).

prop_cluster_correct() ->
    ?SETUP(fun() ->
        eqc_mocking:start_mocking(api_spec(), components()),
        fun() -> ok end
    end,
    ?FORALL(MetaState, dht_routing_meta_eqc:gen_state(),
    ?FORALL(Cmds, eqc_cluster:commands(?MODULE,[{dht_routing_meta_eqc, MetaState}]),
      begin
        {H,S,R} = run_commands(?MODULE, Cmds),
        pretty_commands(?MODULE, Cmds, {H,S,R},
            aggregate(with_title('Commands'), command_names(Cmds),
            collect(eqc_lib:summary('Length'), length(Cmds),
            aggregate(with_title('Features'), eqc_statem:call_features(H),
            features(eqc_statem:call_features(H),
                R == ok)))))
      end))).
    
t() -> t(15).

t(Secs) ->
    eqc:quickcheck(eqc:testing_time(Secs, eqc_statem:show_states(prop_cluster_correct()))).

cmds() ->
  ?LET(MS, dht_routing_meta_eqc:gen_state(),
    eqc_cluster:commands(?MODULE, [{dht_routing_meta_eqc, MS}])).
