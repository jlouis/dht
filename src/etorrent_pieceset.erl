-module(etorrent_pieceset).


-export([new/1,
         empty/1,
         full/1,
         from_binary/2,
         from_bitstring/1,
         to_binary/1,
         from_list/2,
         to_list/1,
         to_string/1,
         is_member/2,
         is_empty/1,
         is_full/1,
         insert/2,
         insert_new/2,
         delete/2,
         intersection/2,
         difference/2,
         size/1,
         capacity/1,
         first/2,
         foldl/3,
         min/1,
         union/1,
         union/2,
         inversion/1,
         progress/1]).

-record(pieceset, {
    size :: non_neg_integer(),
    csize :: non_neg_integer() | none,
    elements :: binary()}).

-type t() :: #pieceset{}.
-export_type([t/0]).

%% @doc
%% Create an empty set of piece indexes. The set of pieces
%% is limited to contain pieces indexes from 0 to Size-1.
%% @end
-spec new(non_neg_integer()) -> t().
new(Size) ->
    Elements = <<0:Size>>,
    #pieceset{size=Size, elements=Elements}.

%% @doc Alias for etorrent_pieceset:new/1
%% @end
-spec empty(non_neg_integer()) -> t().
empty(Size) ->
    new(Size).

%% @doc
%% @end
-spec full(non_neg_integer()) -> t().
full(Size) ->
    Elements = full_(Size, <<>>),
    #pieceset{size=Size, elements=Elements}.

full_(0, Set) ->
    Set;
full_(N, Set) when N >= 16 ->
    full_(N - 16, <<16#FFFF:16, Set/bitstring>>);
full_(N, Set) ->
    full_(N - 1, <<1:1, Set/bitstring>>).


%% @doc
%% Create a piece set based on a bitfield. The bitfield is
%% expected to contain at most Size pieces. The piece set
%% returned by this function is limited to contain at most
%% Size pieces, as a set returned from new/1 is.
%% The bitfield is expected to not be padded with more than 7 bits.
%% @end
-spec from_binary(binary(), non_neg_integer()) -> t().
from_binary(Bin, Size) when is_binary(Bin) ->
    PadLen = paddinglen(Size),
    <<Elements:Size/bitstring, PadValue:PadLen>> = Bin,
    %% All bits used for padding must be set to 0
    case PadValue of
        0 -> #pieceset{size=Size, elements=Elements};
        _ -> erlang:error(badarg)
    end.

%% @doc Construct pieceset from bitstring.
from_bitstring(Bin) ->
    Size = bit_size(Bin),
    #pieceset{size=Size, elements=Bin}.


%% @doc
%% Convert a piece set to a bitfield, the bitfield will
%% be padded with at most 7 bits set to zero.
%% @end
-spec to_binary(Pieceset::t()) -> binary().
to_binary(#pieceset{size=Size, elements=Elements}) ->
    PadLen = paddinglen(Size),
    <<Elements/bitstring, 0:PadLen>>.

%% @doc
%% Convert an ordered list of piece indexes to a piece set.
%% @end
-spec from_list(list(non_neg_integer()), non_neg_integer()) -> t().
from_list(List, Size) ->
    Pieceset = new(Size),
    from_list_(List, Pieceset).

from_list_([], Pieceset) ->
    Pieceset;
from_list_([H|T], Pieceset) ->
    from_list_(T, insert(H, Pieceset)).


%% @doc
%% Convert a piece set to an ordered list of the piece indexes
%% that are members of this set.
%% @end
-spec to_list(t()) -> list(non_neg_integer()).
to_list(Pieceset) ->
    #pieceset{elements=Elements} = Pieceset,
    to_list(Elements, 0).

to_list(<<1:1, Rest/bitstring>>, Index) ->
    [Index|to_list(Rest, Index + 1)];
to_list(<<0:1, Rest/bitstring>>, Index) ->
    to_list(Rest, Index + 1);
to_list(<<>>, _) ->
    [].

%% @doc Convert a piece set of a readable format
%% @end
-spec to_string(t()) -> string().
to_string(Pieceset) ->
    #pieceset{size=Size} = Pieceset,
    Header = io_lib:format("<pieceset(~.10B) ", [Size]),
    Ranges = lists:reverse(foldl(fun to_string_/2, [], Pieceset)),
    Pieces = ["[", [to_string_(Range) || Range <- Ranges], "]"],
    Footer = ">",
    lists:flatten([Header, Pieces, Footer]).

to_string_(Index, []) ->
    [Index];
to_string_(Index, [H|Acc]) when H == (Index - 1) ->
    [{H, Index}|Acc];
to_string_(Index, [{Min, Max}|Acc]) when Max == (Index - 1) ->
    [{Min, Index}|Acc];
to_string_(Index, Acc) ->
    [Index, separator|Acc].

to_string_({Min, Max}) -> [to_string_(Min), "-", to_string_(Max)];
to_string_(separator) -> ",";
to_string_(Index) -> integer_to_list(Index).


%% @doc
%% Returns true if the piece is a member of the piece set,
%% false if not. If the piece index is negative or is larger
%% than the size of this piece set, the function exits with badarg.
%% @end
-spec is_member(non_neg_integer(), t()) -> boolean().
is_member(PieceIndex, _) when PieceIndex < 0 ->
    erlang:error(badarg);
is_member(PieceIndex, Pieceset) ->
    #pieceset{size=Size, elements=Elements} = Pieceset,
    case PieceIndex < Size of
        false ->
            erlang:error(badarg);
        true ->
            <<_:PieceIndex/bitstring, Status:1, _/bitstring>> = Elements,
            Status > 0
    end.

%% @doc
%% Returns true if there are any members in the piece set.
%% @end
-spec is_empty(t()) -> boolean().
is_empty(Pieceset) ->
    #pieceset{size=Size, elements=Elements} = Pieceset,
    <<Memberbits:Size>> = Elements,
    Memberbits == 0.


%% @doc Returns true if there are no members missing from the set
%% @end
-spec is_full(t()) -> boolean().
is_full(Pieceset) ->
    #pieceset{elements=Elements} = Pieceset,
    is_bitstring(Elements) orelse error(badarg),
    is_full_(Elements).

is_full_(<<Pieces:16, Rest/bitstring>>) ->
    (Pieces == 16#FFFF) andalso is_full_(Rest);
is_full_(<<Pieces:8, Rest/bitstring>>) ->
    (Pieces == 16#FF) andalso is_full_(Rest);
is_full_(<<1:1, Rest/bitstring>>) ->
    is_full_(Rest);
is_full_(<<>>) ->
    true;
is_full_(_) ->
    false.



%% @doc
%% Insert a piece into the piece index. If the piece index is
%% negative or larger than the size of this piece set, this
%% function exists with the reason badarg.
%% @end
-spec insert(non_neg_integer(), t()) -> t().
insert(PieceIndex, _) when PieceIndex < 0 ->
    erlang:error(badarg);
insert(PieceIndex, Pieceset) ->
    #pieceset{size=Size, elements=Elements} = Pieceset,
    case PieceIndex < Size of
        false ->
            erlang:error(badarg);
        true ->
            <<Low:PieceIndex/bitstring, _:1, High/bitstring>> = Elements,
            Updated = <<Low/bitstring, 1:1, High/bitstring>>,
            Pieceset#pieceset{elements=Updated}
    end.

insert_new(PieceIndex, Pieceset) ->
    is_member(PieceIndex, Pieceset) andalso error(already_exists),
    insert(PieceIndex, Pieceset).

%% @doc
%% Delete a piece from a pice set. If the index is negative
%% or larger than the size of the piece set, this function
%% exits with reason badarg.
%% @end
-spec delete(non_neg_integer(), t()) -> t().
delete(PieceIndex, _) when PieceIndex < 0 ->
    erlang:error(badarg);
delete(PieceIndex, Pieceset) ->
    #pieceset{size=Size, elements=Elements} = Pieceset,
    case PieceIndex < Size of
        false ->
            erlang:error(badarg);
        true ->
            <<Low:PieceIndex/bitstring, _:1, High/bitstring>> = Elements,
            Updated = <<Low/bitstring, 0:1, High/bitstring>>,
            Pieceset#pieceset{elements=Updated}
    end.

%% @doc
%% Return a piece set where each member is a member of both sets.
%% If both sets are not of the same size this function exits with badarg.
%% @end
-spec intersection(t(), t()) -> t().
intersection(Set0, Set1) ->
    #pieceset{size=Size0, elements=Elements0} = Set0,
    #pieceset{size=Size1, elements=Elements1} = Set1,
    case Size0 == Size1 of
        false ->
            erlang:error(badarg);
        true ->
            <<E0:Size0>> = Elements0,
            <<E1:Size1>> = Elements1,
            Shared = E0 band E1,
            Intersection = <<Shared:Size0>>,
            #pieceset{size=Size0, elements=Intersection}
    end.

-spec union(t(), t()) -> t().
union(Set0, Set1) ->
    #pieceset{size=Size, elements = Elements0} = Set0,
    #pieceset{size=Size, elements = Elements1} = Set1,
    <<E0:Size>> = Elements0,
    <<E1:Size>> = Elements1,
    Union = <<(E0 bor E1):Size>>,
    #pieceset{size=Size, elements=Union}.

union([H|T]) ->
    #pieceset{size=Size, elements = ElementsH} = H,
    <<EH:Size>> = ElementsH,
    F = fun(X, Acc) ->
        #pieceset{size=Size, elements = <<EX:Size>>} = X,
        EX bor Acc
        end,
    Union = lists:foldl(F, EH, T),
    #pieceset{size = Size, elements = <<Union:Size>>}.
    

%% @doc
%% Return a piece set where each member is a member of the first
%% but not a member of the second set.
%% If both sets are not of the same size this function exits with badarg.
%% @end
difference(Set0, Set1) ->
    #pieceset{size=Size0, elements=Elements0} = Set0,
    #pieceset{size=Size1, elements=Elements1} = Set1,
    case Size0 == Size1 of
        false ->
            erlang:error(badarg);
        true ->
            <<E0:Size0>> = Elements0,
            <<E1:Size1>> = Elements1,
            Unique = (E0 bxor E1) band E0,
            Difference = <<Unique:Size0>>,
            #pieceset{size=Size0, elements=Difference}
    end.


%% @doc
%% Return the number of pieces that are members of the set.
%% @end
-spec size(t()) -> non_neg_integer().
size(Pieceset) ->
    #pieceset{elements=Elements} = Pieceset,
    size(Elements, 0).

size(<<1:1, Rest/bitstring>>, Acc) ->
    size(Rest, Acc + 1);
size(<<0:1, Rest/bitstring>>, Acc) ->
    size(Rest, Acc);
size(<<>>, Acc) ->
    Acc.

%% @doc Return the number of pieces that can be members of the set
%% @end
-spec capacity(t()) -> non_neg_integer().
capacity(Pieceset) ->
    #pieceset{size=Size} = Pieceset,
    Size.


inversion(Set) ->
    #pieceset{elements=Elements, size=Size} = Set,
    <<E0:Size>> = Elements,
    E1 = bnot E0,
    Elements1 = <<E1:Size>>,
    Set#pieceset{elements=Elements1}.


%% @doc Return float from 0 to 1.
-spec progress(t()) -> float().
progress(Pieceset) ->
    etorrent_pieceset:size(Pieceset) / capacity(Pieceset).


%% @doc Return the first member of the list that is a member of the set
%% If no element of the list is a member of the set the function exits
%% with reason badarg. This function assumes that all pieces in the lists
%% are valid.
%% @end
-spec first([non_neg_integer()], t()) -> non_neg_integer().
first(Pieces, Pieceset) ->
    #pieceset{elements=Elements} = Pieceset,
    first_(Pieces, Elements).

first_([], _) ->
    erlang:error(badarg);
first_([H|T], Elements) ->
    <<_:H/bitstring, Status:1, _/bitstring>> = Elements,
    case Status of
        1 -> H;
        0 -> first_(T, Elements)
    end.

%% @doc Iterate over the members of a piece set
%% @end
foldl(Fun, Acc, Pieceset) ->
    #pieceset{elements=Elements} = Pieceset,
    foldl_(Fun, Acc, Elements, 0).

foldl_(Fun, Acc, <<1:1, Rest/bitstring>>, Index) ->
    NewAcc = Fun(Index, Acc),
    foldl_(Fun, NewAcc, Rest, Index + 1);
foldl_(Fun, Acc, <<0:1, Rest/bitstring>>, Index) ->
    foldl_(Fun, Acc, Rest, Index + 1);
foldl_(_, Acc, <<>>, _) ->
    Acc.



%% @doc
%% Return the lowest piece index that is a member of this set.
%% If the piece set is empty, exit with reason badarg
%% @end
-spec min(t()) -> non_neg_integer().
min(Pieceset) ->
    #pieceset{elements=Elements} = Pieceset,
    min_(Elements, 0).

min_(Elements, Offset) ->
    Half = bit_size(Elements) div 2,
    case Elements of
        <<>> ->
            erlang:error(badarg);
        <<0:1>> ->
            erlang:error(badarg);
        <<1:1>> ->
            Offset;
        <<0:Half, Rest/bitstring>> ->
            min_(Rest, Offset + Half);
        <<Rest:Half/bitstring, _/bitstring>> ->
            min_(Rest, Offset)
    end.

paddinglen(Size) ->
    Length = 8 - (Size rem 8),
    case Length of
        8 -> 0;
        _ -> Length
    end.


