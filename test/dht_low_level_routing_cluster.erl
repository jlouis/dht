-module(dht_low_level_routing_cluster).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_cluster.hrl").
-compile(export_all).

components() -> [
	dht_routing_meta_eqc,
	dht_routing_table_eqc
].
