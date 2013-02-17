%% @doc Encode/Decode bencoded data.
%% their encoding.</p>
%% etorrent_bcoding
%%
%% It is a special case for decoding `data' message.
%% http://www.bittorrent.org/beps/bep_0009.html
-module(etorrent_bcoding2).
-author("Uvarov Mochael <arcusfelis@gmail.com>").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
-export([decode/1]).

-type bcode() :: etorrent_types:bcode().

%%====================================================================
%% API
%%====================================================================

decode(Msg) when is_binary(Msg) ->
    decode_b(Msg).

%%====================================================================

decode_b(<<H, Rest/binary>> = Bin) ->
    case H of
        $i ->
            decode_integer(Rest);
        $l ->
            decode_list(Rest);
        $d ->
            decode_dict(Rest);
        $e ->
            {end_of_data, Rest};
        _ ->
            %% This might fail, and so what ;)
            attempt_string_decode(Bin)
    end.

%% <string length encoded in base ten ASCII>:<string data>
attempt_string_decode(Bin) when is_binary(Bin) ->
    [Number, Data] = binary:split(Bin, <<$:>>),
    ParsedNumber = list_to_integer(binary_to_list(Number)),
    <<StrData:ParsedNumber/binary, Rest/binary>> = Data,
    {StrData, Rest}.

%% i<integer encoded in base ten ASCII>e
decode_integer(Bin) ->
    [IntBin, RestPart] = binary:split(Bin, <<$e>>),
    Int = list_to_integer(binary_to_list(IntBin)),
    {Int, RestPart}.

%% l<bencoded values>e
decode_list(Bin) ->
    {ItemTree, Rest} = decode_list_items(Bin, []),
    {ItemTree, Rest}.

decode_list_items(<<>>, Accum) -> {lists:reverse(Accum), []};
decode_list_items(Items, Accum) ->
    case decode_b(Items) of
        {end_of_data, Rest} ->
            {lists:reverse(Accum), Rest};
        {I, Rest} -> decode_list_items(Rest, [I | Accum])
    end.

decode_dict(Bin) ->
    decode_dict_items(Bin, []).

decode_dict_items(<<>>, Accum) ->
    {Accum, <<>>};
decode_dict_items(Bin, Accum) when is_binary(Bin) ->
    case decode_b(Bin) of
        {end_of_data, Rest} when Accum == [] -> {{}, Rest};
        {end_of_data, Rest} -> {lists:reverse(Accum), Rest};
        {Key, Rest1} -> {Value, Rest2} = decode_b(Rest1),
                        decode_dict_items(Rest2, [{Key, Value} | Accum])
    end.

-ifdef(TEST).
decode_test_() ->
    [?_assertEqual(decode(<<"d8:msg_typei0e5:piecei0ee">>),
                   {[{<<"msg_type">>, 0}, {<<"piece">>, 0}], <<"">>})].

-endif.
