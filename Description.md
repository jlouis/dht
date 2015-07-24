# A description of DIDS—Distributed ID Service

This is a Distributed ID Service, or DIDS. The project started out as a Distributed Hash Table, but thinking about it more had me realize it is not really a DHT, but something else. Therefore it is more apt to rename stuff to make it clear what kind of service we provide.

So what is a Distributed Identity Service? It is a service in which we ultimately want to provide a mapping

	Identity -> Location*
	
That is, given an identity, we obtain the locations where can we find it. In our system, we rely on the IP protocol, so in our system we define locations as IP addresses and we define identities as very large integers. So we have:

	Identity ::= 256 bit integer
	Location ::= {inet:ip_address(), inet:port_number()}
	
and the DIDS maps Identities into Locations, nothing more. But it does so in a distributed fashion, in order to provide a no-single-point-of-failure.

The *distributed* part is that DIDS nodes are part of a *swarm* of other nodes they know about. Some queries—which can't be satisfied locally—can ask other nodes in swarm for the locations. This provides the system with robustness and no single-point-of-failure.

The DIDS system keeps a *partial* routing table of all nodes known in the swarm. The property is chosen such that nodes which are "close" are more likely to be in the routing table, and nodes which are far away are less like to be there. This allows us to query foreign nodes for a given Identity and its locations, should we not have it in our local cache. Querying will necessary be limited by network round trips. That it, query is relatively fast, but it is not blindingly fast. We have deliberately built the system for robustness of keeping values rather than being fast.

## TL;DR version

DIDS is essentially a global DNS service with no single point of failure and no hierarchy of machines within the infrastructure. It is a big dynamic swarm of machines covering for each other. It provides a mapping of *identities* into *locations* much like DNS does. The details are different, but the general idea is the same: you can use this from within Erlang to create large naming registries.

## Important properties

A DIDS never stores data back to "Itself". That is, A given node is *never* its own client. This is in contrast with other systems, like the Dynamo ring used by Amazon and Riak, where some queries are to the node "itself" and acts exactly like another node in the ring. When you store Identities in the swarm, you are always storing identities in some other place than in your own node. This is because it is assumed you already store locally in your own cache, so there is no need to handle this.

(Note: the API should make it easy to handle this at the top-level, so you don't have to go and worry about this. But it is not really fleshed out how to do this in detail, actually).

# Uses

Typical use cases are:

* Data repositories for persistent data. Package repositories.
* World-wide global file systems.
* Very large scale file systems in large distributed data centers.
* Naming services with no central authority.
* Global dynamic DNS registry for Erlang nodes.

# Non-goals

A DIDS is different from a DHT. Specifically, we need to address a number of points it doesn't try to solve:

* We do not map `Key -> Value`. This is to avoid the trap of building a system which also takes care of storage. We don't care about how data are actually stored. The only thing we do is to provide a way in which you can get locations of the given Identity. You can use any storage system you want with DIDS.

* The DIDS does not persist data at all. If an Identity is pushed to the swarm it has to be refreshed at a given interval, or it will stop being in the swarms global knowledge. This is to make sure the swarm is fairly dynamic in the way it works and to protect it: If you have millions of entries you wish the swarm to manage, you have work to do in order to push out these identities at regular intervals. (In time, we will provide ways to make the DIDS system refresh its kept values).

* We do not define a protocol for grabbing the actual data. This means you can build this on top of other services. You could for instance define that a hexadecimal representation of the ID, is what you are using. And that if the location of the form `10.0.x.y:8080` then you should run a request
	http://10.0.x.y:8080/c/54bad3fa…
	
to obtain data. It is entirely up to you how the identity should be interpreted. You can even let them represent Infohashes for torrents if you want. It is the same idea that drives the distributed hash table in the BitTorrent network.

# API

We support 4 commands:

* PING(Peer): Ask another node in the swarm if it lives
* FIND_NODE(ID): Find a node with a given ID
* FIND_VALUE(ID): Find nodes which has the given ID associated with them.
* STORE(ID, Port): Store the fact that ID can be obtained on this Node by contacting it on the port `Port`. The IP is implicitly derived. The IP is implicitly derived because we don't want enemies to be able to store an arbitrary IP address in the swarm, but only addresses for which the packet originate. When we return that we are willing to handle a value for a peer, we give that peer an unique token back. They have to supply this token to us, or we reject the store in our end of the system. This ensures the peer has actually contacted us recently to store a value. Tokens stop being valid a minute in.

Notes: Values can *never* be deleted but given enough time and no refreshing STORE command, they will automatically dissipate from the cloud. Unless some other node decides to keep the reference alive.

# Rules

* Your identities must be drawn from the 256 bit unsigned integer space uniformly. In Erlang, one way to do this is to take the data you wish to store and index it based on its content. Given `Content` run `ID  = crypto:hash(sha256, Content)` and store the ID pointing back to you.

* Nodes in the swarm pick random IDs in the 256 bit space as well. They have to in order to achieve good spread. Otherwise the system can degenerate.

# Inspiration:

* The `Kademlia` Distributed Hash Table ( http://pdos.csail.mit.edu/~petar/papers/maymounkov-kademlia-lncs.pdf ).
* The `BitTorrent` DHT implementation documented in `BEP 005`.
