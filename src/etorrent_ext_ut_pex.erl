-module(etorrent_ext_ut_pex).
-export([decode_msg/1,
         encode_msg/1]).

decode_msg(Msg) when is_binary(Msg) ->
    {ok, Dict} = etorrent_bcoding:decode(Msg),
    lager:debug("PEX message ~p.", [Dict]),
    Added    = proplists:get_value(<<"added">>, Dict, <<>>),
    AddedF   = proplists:get_value(<<"added.f">>, Dict, <<>>),
    Dropped  = proplists:get_value(<<"dropped">>, Dict, <<>>),
    DroppedF = proplists:get_value(<<"dropped.f">>, Dict, <<>>),
    AddedA   = decode_ipv4_list(Added),
    DroppedA = decode_ipv4_list(Dropped),
    IPs      = [IP || {IP,_} <- AddedA ++ DroppedA],
%% * ``added`` must not contain duplicate addresses.  Having a different
%%   port number does not make an address different.
%% * ``dropped`` must not contain duplicate addresses.  Having a
%%   different port number does not make an address different.
%% * ``dropped`` must not contain any addresses that are also in ``added``.
    [error(has_duplicates) || has_duplicates(IPs)],
    PL = [{added,   merge_addresses_and_flags(AddedA, decode_flags(AddedF))},
          {dropped, merge_addresses_and_flags(DroppedA, decode_flags(DroppedF))}],
    {pex, PL}.


encode_msg({pex, _Dict}) -> <<>>.

decode_ipv4_list(Bin) ->
    [{{A,B,C,D}, Port} || <<A,B,C,D, Port:16/big>> <= Bin].


decode_flags(Bin) ->
    [flags_to_list(X) || X <- binary_to_list(Bin)].

flags_to_list(X) when is_integer(X) ->
    [Name || {Pos, Name} <- bit_to_name(), is_bit_set(X, Pos)].

%% @doc Is bit `N' is set in `X'.
is_bit_set(X, N) ->
    X band bit_to_int(N) > 0.

bit_to_int(N) ->
    1 bsl N.

bit_to_name() ->
    [{0, default},
     {1, prefer_enctryption},
     {2, is_seeder}].


%% * ``added.f`` must be no longer than the number of addresses in
%%   ``added``.  It is allowed to have one that is shorter. 
merge_addresses_and_flags([], []) -> [];
merge_addresses_and_flags([_|_]=Addresses, []) ->
    [{IP, Port, []} || {IP,Port} <- Addresses]; 
merge_addresses_and_flags([{IP,Port}|Addresses], [FlagsH|FlagsT]) ->
    [{IP, Port, FlagsH} | merge_addresses_and_flags(Addresses, FlagsT)].


has_duplicates(List) ->
    SList = lists:sort(List),
    length(lists:sort(SList)) =/= length(SList).
