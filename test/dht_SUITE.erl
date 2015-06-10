-module(dht_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eqc/include/eqc_ct.hrl").

-compile(export_all).

suite() ->
    [{timetrap, {seconds, 15}}].
    
init_per_group(_Group, Config) ->
    Config.

end_per_group(_Group, _Config) ->
    ok.

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_Case, Config) ->
    Config.

end_per_testcase(_Case, _Config) ->
    ok.

metric_group() -> [{metric, [shuffle], [
	check_metric_refl,
	check_metric_sym,
	check_metric_triangle_ineq
    ]}].
    
state_group() -> [{state, [shuffle], [
	check_routing_table,
	check_routing_meta,
	check_state
    ]}].
    
network_group() -> [{network, [shuffle], [
	check_protocol_encoding
    ]}].

utility_group() -> [{utility, [shuffle], [
	check_rand_pick
    ]}].

groups() ->
    lists:append([
	utility_group(),
	metric_group(),
	state_group(),
	network_group()
    ]).

all() ->
  [{group, utility},
   {group, metric},
   {group, state},
   {group, network}].

%% TESTS
%% ----------------------------------------------------------------------------
check_rand_pick(_Config) ->
    ?quickcheck((dht_rand_eqc:prop_pick())).

check_metric_refl(_Config) ->
    ?quickcheck((dht_metric_eqc:prop_op_refl())).
    
check_metric_sym(_Config) ->
    ?quickcheck((dht_metric_eqc:prop_op_sym())).
    
check_metric_triangle_ineq(_Config) ->
    ?quickcheck((dht_metric_eqc:prop_op_triangle_ineq())).

check_protocol_encoding(_Config) ->
    ?quickcheck((dht_proto_eqc:prop_iso_packet())).

check_routing_table(_Config) ->
    ?quickcheck((dht_routing_table_eqc:prop_component_correct())).

check_routing_meta(_Config) ->
    ?quickcheck((dht_routing_meta_eqc:prop_component_correct())).
    
check_state(_Config) ->
    ?quickcheck((dht_state_eqc:prop_component_correct())).