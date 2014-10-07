# DHT Protocol design

A far-reaching DHT for Erlang nodes needs a protocol which is different from the BitTorrent DHT protocol. In BitTorrent, we utilize the common interchange format for BitTorrent, *bencoding*, in order to convey information between nodes. Messages are exchanged via UDP in a quick Request/Response pattern and there is some cookie-employment in order to protect against rogue nodes going havoc and destroying the DHT cloud in its entirety.

The problem with a DHT built for world-wide adaption is *trust*. We can't in general trust other nodes to produce meaningful inputs. An evil system can easily send us random garbage in order to mess with us. Therefore, the format we propose must be resilient against that. Hence, we propose a simple format, with few moving parts in order to make it harder to untrusted parties to mess with our system.

This file only contains the parts of the protocol which has to do with sending and receiving messages on the wire. The parts which has to do with the high-level DHT semantics has to go elsewhere. This split makes it possible to focus on one thing at a time, and produce better software, hopefully.

We avoid using the Erlang Term binary format for this reason. It is a format which is excellent between trusted participants, but for an untrusted node, it is not so good. We opt instead for a binary format with a very simple and well-defined tree-like structure we can parse by binary pattern matchings in Erlang. Great care has been taken to make the parse as simple as possible as to avoid parsing ambiguities:

* The format can be parsed from the head through a simple EBNF-like grammar structure.
* Length fields are kept to a minimum and it is made such that the grammar is easy to parse as an LL(1) parser by recursive descent.
* Great care has been placed on limiting the size of various fields such that it is not possible to mis-parse data by reading strings incorrectly.
* The parser has been made so it is suited for Erlang binary pattern matching parsing.

# Deviations from Kademlia

We deviate from the Kademlia paper in one very important aspect. In Kademlia, you store pairs of Key/Value. In our distributed network, you store identifications of a Key to the IP/Port pairs that have the key. It is implicitly expected that the identification is enough to satisfy what kind of protocol we are speaking. That is, if we are given `10.18.19.20` at port `80`, for key ID `0xc0ffecafe`, we can build things on the assumption that requesting `http://10.18.19.20/v/c0ffecafe` will obtain the value for that key. So this protocol doesn't store values themselves, but only a mapping from the world of Key material into an IP world where we can retrieve the given values.

This design choice is made to keep the DHT as simple as possible. For most systems, this is enough and the only facility that the DHT should provide is a way to identify who has what in a decentralized and distributed fashion. The actual storage of data is left to another system in a typical layered model.
 
# Syntax

Messages are exchanged as packets. The UDP packets has this general framing form:

	Packet ::= <<"EDHT-KDM-", Version:8/integer, Tag:16/integer, Msg/binary>>
	
The "EDHT-KDM-" header makes it possible to remove spurious messages that accidentally hit the port. The Version allows us 256 versions so we can extend the protocol later. I propose a binary protocol which is not easily extensible indefinitely, although certain simple extensions are possible. It is not our intent that this protocol is to be used by other parties, except for the Erlang DHT cloud. Hence, we keep the format simple in version 0. If we hit extension hell, we can always propose a later version of the protocol, parsing data differently. In that situation, we probably extend the protocol with a self-describing data set like in ASN.1.

The `Tag` value encodes a 16 bit value which is selected by the querying entity. And it is reflected in the message from the responding entity. This means you can match up the values and have multiple outstanding requests to the same node in question. It also makes it easy to track outstanding requests, and correlate them to waiting processes locally.

The tag is not meant to be a security feature. A random attacker can easily forge reply-packets given the tag size. On the other hand, it would not provide much added security if we extended the tag to a 128 bit random value, say. In this case, eavesdropping eve can just sniff the query packet and come up with a fake reply to that query. As such, it is possible to steer the replies.

Messages are not length-coded directly. The remainder of the UDP packet is the message. Note that implementations are free to limit the message lengths to 1024 bytes if they want. This is to protect against excessively overloading a node. There are three types of messages:

	Msg ::=
		| <<$q, QueryMsg/binary>>
		| <<$r, ReplyMsg/binary>>
		| <<$e, ErrMsg/binary>>

For each kind of query, there is a corresponding reply. So if the query type is `K` then `qK` has a reply `rK`. The formats of the request and the reply are different however. Errors also follow this convention, but it is strictly not needed since all error responses follow the same form. The rules are for queries, Q, replies R and errors E there are two valid transitions:

	either
		Q → R		(reply)
	or
		Q → E		(error)

That is, either a query results in a reply or an error but never both. We begin by handling Errors because they are the simplest:

	ErrMsg ::= <<ErrCode:16, ErrString/binary>>		length(ErrString) =< 1024 bytes
	ErrString <<X/utf8, …>>

We limit the error message to 1024 *bytes*. We don't want excessive parses of large messages here, so we keep it short. The `ErrCode` entries are taken from an Error Code table, given below, together with its error message. The list is forward extensible.

# Security considerations:

A DHT like Kademlia uses random Identities chosen for nodes. And chooses a cryptographic hash function to represent the identity of content. Given bytes `Bin`, the ID of the binary `Bin` is simple the value `crypto:hash(sha256, Bin)`. Hence, the strength of the integrity guarantee we provide is given by the strength of the hash function we pick.

* Confidentiality: No confidentiality is provided. Everyone can snoop at what you are requesting at any point in time. 

* Integrity: Node-ID and Key-ID identity is chosen to be SHA-256. This is a change from SHA-1 used in Kademlia back in 2001. SHA-1 has collision problems in numerous ways at the moment so in order to preserve 2nd preimage resistance, and obtain proper integrity, we need at least SHA-256. SHA-3 or SHA-512 are also possible for extending the security margin further, but we can do so in a later version of the protocol. I've opted *not* to make the hash-function negotiable. If an error crops up in SHA-256, we bump the protocol number and rule out any earlier request as being invalid. This also builds in a nice self-destruction mechanism, so safe clients don't accidentally talk to insecure clients.

* Availability: The protocol is susceptible to several attacks on its availability. The protection against it is a "enough nodes" defense, much like the one posed in BitCoin, but it is somewhat shady. If nodes lie about routing information or if a node is flooded with requests it will cease to operate correctly. Hopefully the sought-after value is at multiple nodes, so this doesn't pose a problem. But in itself, there is no protection against availability.

The key take-away from the DHT method is that it provides integrity, but not confidentiality nor availability. If you receive a key K, the content addressing of the value V associated with K is what protects you against forged data. Under the assumption the cryptographic hash function is safe that is.

# Common entities

The format uses a set of common data types which are described here:

	SHA_ID ::= <<ID:256>>
	IP4 ::= <<B1, B2, B3, B4, Port:16>>		Parse as {{B1, B2, B3, B4}, Port} for an IPv4 socket
	IP6 ::= <<B1, B2, B3, B4, B5, B6, B7, B8, Port:16>>	Parse as {{B1, B2, B3, B4, B5, B6, B7, B8}, Port} for an IPv6 socket

The SHA_ID refers to a 256 bit SHA-256 bit sequence. It is used to uniquely identify nodes and keys in the DHT space. The values IP4 and IP6 refers to Peers given by an IP address and a Port number on which to contact a peer. The two values correspond to IPv4 and IPv6 addressing respectively.

# Commands

Each command is a Query/Reply pair. The format of the query and its reply are usually not the same, but they are connected since each query result in a reply. This means that there is a rule that a query for command K must result in a reply of type K. Otherwise things are wrong. This is easily handled in a parser. Furthermore, it means we can parse replies without having to tell the parser what command to expect before we try to parse the reply. It neatly decouples the syntax of the protocol from its semantics in the protocol.

In the following, it is always an exchange between Alice and Bob, where Alice sends a Query-message to Bob which then replies back with a Reply-message. But of course, in a real peer-to-peer network, the roles can easily be the reversed order in practice. We just pick names here for the purpose of meaningful explanation.

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

The `s` command stores the availability of a Key in the cloud:

	QueryMsg ::= …
		| <<$s, $4, KEY, Token:64, IP4/binary>>
		| <<$s, $6, KEY, Token:64, IP6/binary>>
	ReplyMsg ::= …
		| <<$s>>

	Key ::= SHA_ID
	
Store a mapping `KEY → Val` under this node. Each known Node-ID is allowed once such entry in the table. A node is allowed to limit the amount of values it stores for other nodes here.

#  Extensions

We give extensions as DEPs (Distributed-hash-table Extension Proposals)

## DEP001: MAC'ed messages

Let `S` be a secret shared by all peers. Then 

	MacPacket ::= <<"EDHT-KDM-M-", Version:8/integer, Tag:16/integer, Msg/binary, MAC:256>>
	
is a MAC-encoded packet, which is encoded as a normal packet, except that it has another header and contains a 256 bit MAC (Message Authentication Code). Clients handle this packet by checking the MAC against `S`. If it fails to pass the check, the packet is thrown away on the grounds of a MAC error. This allows people to create "local" DHT clouds which has no other participants than the designated. There is no accidental situation which can make this DHT merge with other DHTs or the world at large.

Strict rule: You *MUST* verify the MAC before you attempt to decode the packet in an implementation. This guards against malicious users trying to inject messages/packets into the cloud you have built and trusted.

In a large setting, this partially addresses the availability of the DHT. An adversary in the middle, Mallory, can't inject packets into our DHT which it then tries to handle. Also, unless you have `S`, you can't communicate with the DHT. Note that this doesn't provide confidentiality of packet messages.

## DEP002: NACL encrypted messages

TODO—NACL encrypted exchanges with shared secrets.

# Error Codes and their messages

TODO
