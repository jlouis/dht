# DHT Protocol design

A far-reaching DHT for Erlang nodes needs a protocol which is different from the BitTorrent DHT protocol. In BitTorrent, we utilize the common interchange format for BitTorrent, *bencoding*, in order to convey information between nodes. Messages are exchanged via UDP in a quick Request/Response pattern and there is some cookie-employment in order to protect against rogue nodes going havoc and destroying the DHT cloud in its entirety.

The problem with a DHT built for world-wide adaption is *trust*. We can't in general trust other nodes to produce meaningful inputs. An evil system can easily send us random garbage in order to mess with us. Therefore, the format we propose must be resilient against that. Hence, we propose a simple format, with few moving parts in order to make it harder to untrusted parties to mess with our system.

This file only contains the parts of the protocol which has to do with sending and receiving messages on the wire. The parts which has to do with the high-level DHT semantics has to go elsewhere. This split makes it possible to focus on one thing at a time, and produce better software, hopefully.

We avoid using the Erlang Term binary format for this reason. It is a format which is excellent between trusted participants, but for an untrusted node, it is not so good. We opt instead for a binary format with a very simple and well-defined tree-like structure we can parse by binary pattern matchings in Erlang. Great care has been taken to make the parse as simple as possible as to avoid parsing ambiguities:

* The format can be parsed from the head through a simple EBNF-like grammar structure.
* Length fields are kept to a minimum and it is made such that the grammar is easy to parse as an LL(1) parser by recursive descent.
* Great care has been placed on limiting the size of various fields such that it is not possible to mis-parse data by reading strings incorrectly.
* The parser has been made so it is suited for Erlang binary pattern matching parsing.

Messages are exchanged as packets. The UDP packets has this general framing form:

	Packet ::= <<"EDHT-KDM-", Version:8/integer, Tag:16/integer, Msg/binary>>
	
The "EDHT-KDM-" header makes it possible to remove spurious messages that accidentally hit the port. The Version allows us 256 versions so we can extend the protocol later. I propose a binary protocol which is not easily extensible indefinitely, altough certain simple extensions are possible. It is not our intent that this protocol is to be used by other parties, except for the Erlang DHT cloud. Hence, we keep the format simple in version 0. If we hit extension hell, we can always propose a later version of the protocol, parsing data differently. In that situation, we probably extend the protocol with a self-describing data set like in ASN.1.

The `Tag` value encodes a 16 bit value which is selected by the querying entity. And it is reflected in the message from the responding entity. This means you can match up the values and have multiple outstanding requests to the same node in question. It also makes it easy to track outstanding requests, and correlate them to waiting processes locally.

The tag is not meant to be a security feature. A random attacker can easily forge reply-packets given the tag size. On the other hand, it would not provide much added security if we extended the tag to a 128 bit random value, say. In this case, eavesdropping eve can just sniff the query packet and come up with a fake reply to that query. As such, it is possible to steer the replies.

Messages are not length-coded directly. The remainder of the UDP packet is the message. Note that implementations are free to limit the message lengths to 1024 bytes if they want. This is to protect against excessively overloading a node. There are three types of messages:

	Msg ::=
		| <<$q, QueryMsg/binary>>
		| <<$r, ReplyMsg/binary>>
		| <<$e, ErrMsg/binary>>

For each kind of query, there is a corresponding reply. So if the query type is `K` then `qK` has a reply `rK`. The formats of the request and the reply are different however. Errors also follow this convention, but it is strictly not needed since all error responses follow the same form. The rules are for queries, Q, replies R and errors E there are two valid transitions:

	either
		Q → R
	or
		Q → E

That is, either a query results in a reply or an error but never both. We begin by handling Errors because they are the simplest:

	ErrMsg ::= <<ErrCode:16, ErrString/binary>>		length(ErrString) =< 1024 bytes
	ErrString <<X/utf8, …>>

We limit the error message to 1024 *bytes*. We don't want excessive parses of large messages here, so we keep it short. The `ErrCode` entries are taken from an Error Code table, given below, together with its error message. The list is forwards extensible.

# Security considerations:

A DHT like Kademlia uses random Identities chosen for nodes. And chooses a cryptographic hash function to represent the identity of content. Given bytes `Bin`, the ID of the binary `Bin` is simple the value `crypto:hash(sha256, Bin)`. Hence, the strenght of the integrity guarantee we provide is given by the strength of the hash function we pick.

* Confidentiality: No confidentiality is provided. Everyone can snoop at what you are requesting at any point in time. 

* Integrity: Node-ID and Key-ID identity is chosen to be SHA-256. This is a change from SHA-1 used in Kademlia back in 2001. SHA-1 has collision problems in numerous ways at the moment so in order to preserve 2nd preimage resistance, and obtain proper integrity, we need at least SHA-256. SHA-3 or SHA-512 are also possible for extending the security margin further, but we can do so in a later version of the protocol. I've opted *not* to make the hash-function negotiateable. If an error crops up in SHA-256, we bump the protocol number and rule out any earlier request as being invalid. This also builds in a nice self-destruction mechanism, so safe clients don't accidentally talk to insecure clients.

* Availability: The protocol is susceptible to several attacks on its availability. The protection against it is a "enough nodes" defense, much like the one posed in BitCoin, but it is somewhat shady. If nodes lie about routing information or if a node is flooded with requests it will cease to operate correctly. Hopefully the sought-after value is at multiple nodes, so this doesn't pose a problem. But in itself, there is no protection against availability.

The key take-away from the DHT method is that it provides integrity, but not confidentiality nor availability. If you receive a key K, the content addressing of the value V associated with K is what protects you against forged data. Under the assumption the cryptographic hash function is safe that is.

# Common entities

The format uses a set of common data types which are described here:

	SHA_ID ::= <<ID:256>>

# Commands

Each command is a Query/Reply pair. The format of the query and its reply are usually not the same, but they are connected since each query result in a reply. It is always an exchange between Alice and Bob, where Alice sends a Query-message to Bob which then replies back with a Reply-message. But of course, in a real peer-to-peer network, the roles can easily be the reversed order in practice. We just pick names here for the purpose of meaningful explanation.

All commands are 1-byte values. We deliberately pick the values such that the commands have mnemonics. In principle it just encodes a one-byte enumeration of the different kinds of message types.

A peer is free to return an error back if it wants. But clients should be prepared for timeouts. Overloaded clients might limit responses to other parties.

## `p`—Ping a node to check its availability

A `p` command is used to check for availability of a peer:

	QueryMsg ::= <<$p, SHA_ID>>
	ReplyMsg ::= <<$p, SHA_ID>>

Alice sends her Node-ID SHA to Bob and Bob replies back with his Node-ID. This is used to learn that another node is up and running, or is not responding to pings right now.

## `n`—Search for a node with a given ID

TODO

## `v`—Get a list of peers which are closer to a given Key-ID value

TODO

## `s`—Store a Key/Value pair in the DHT cloud

*NOTE:* This is not right at the moment, and needs more work. In particular, there are currently no Tokens here.

The `s` command stores Key/Value pairs in the cloud. They have the following form:

	QueryMsg ::= …
		| <<$s, KEY, Val/binary>>		length(Val) =< 1024
	ReplyMsg ::= …
		| <<$s>>

	Key ::= SHA_ID
	
Store a mapping `KEY → Val` under this node. Each known Node-ID is allowed once such entry in the table. A node is allowed to limit the amount of values it stores for other nodes here.

#  Extensions

## MAC'ed messages

Let `S` be a secret shared by all peers. Then 

	MacPacket ::= <<"EDHT-KDM-M-", Version:8/integer, Tag:16/integer, Msg/binary, MAC:256>>
	
is a normal packet, except that it has another header and contains a 256 bit MAC (Message Authenticaton Code). Clients handle this packet by checking the MAC against `S`. If it fails to pass the check, the packet is thrown away on the grounds of a MAC error. This allows people to create "local" DHT clouds which has no other participants than the designated. There is no accidental situation which can make this DHT merge with other DHTs or the world at large.

## NACL encrypted messages

TODO—NACL encrypted exchanges with shared secrets.

# Error Codes and their messages

TODO