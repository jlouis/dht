-module(dht_state_eqc).
-compile(export_all).

-include_lib("eqc/include/eqc.hrl").

bucket() ->
    ?SIZED(Size, well_defined(bucket(Size))).
    
bucket(0) ->
  oneof([
    {call, dht_bucket, new, []}
  ]);
bucket(_N) ->
  frequency([
      {5, bucket(0)}
  ]).
  
prop_total() ->
    ?FORALL(B, bucket(),
        begin
            eval(B),
            true
        end).
