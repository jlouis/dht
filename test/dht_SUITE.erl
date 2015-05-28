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

dht_group() -> [{eqc, [shuffle], [
	check_routing_table_seq,
	check_protocol_encoding,
	check_routing_system_seq
    ]}].

groups() ->
    [{basic, [shuffle], [dummy]}]
    ++ dht_group().

all() ->
  [{group, basic},
   {group, eqc}].

%% TESTS
%% ----------------------------------------------------------------------------
dummy(_Config) ->
    ok.

check_routing_table_seq(_Config) ->
    ?quickcheck((dht_routing_table_eqc:prop_seq())).

check_protocol_encoding(_Config) ->
    ?quickcheck((dht_proto_eqc:prop_iso_packet())).

check_routing_system_seq(_Config) ->
    ?quickcheck((dht_routing_meta_eqc:prop_routing_correct())).