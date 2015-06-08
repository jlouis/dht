-module(dht_low_level_routing_cluster).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_cluster.hrl").
-compile(export_all).

components() -> [
	dht_routing_meta_eqc,
	dht_routing_table_eqc
].

gen_commands() ->
    ?LET(
      {TableState, MetaState},
      {dht_routing_table_eqc:gen_state(), dht_routing_meta_eqc:gen_state()},
        eqc_cluster:commands(?MODULE, [
            {dht_routing_meta_eqc, MetaState},
            {dht_routing_table_eqc, TableState}
        ])).
        
t() ->
    eqc_gen:sample(gen_commands()).
