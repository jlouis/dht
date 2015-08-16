# dht — Distributed Hash Table for Erlang

The `dht` application implements a Distributed Hash Table for Erlang. It is excised from the etorrent application in order to make it possible to use it without using the rest of etorrent.

The code is highly rewritten by now. There are few traces left of the original code base. The reason for the partial rewrite was to support a full QuickCheck model, so code was changed in order to make certain parts easier to handle from a formal point of view.

# State of the code

The code is currently early alpha state, and things may not work yet. In particular, many parts of the system has not been thoroughly tested and as such they may contain grave bugs. While each subsystem has been tested in isolation, it still remains to build QuickCheck models which assembles all those subsystems. This will probably turn up errors.

Check the issues at github. They may contain current problems.

## Flag days

Since we are at an early alpha, changes will be made which are not backwards compatible. This section describes the so-called “flag days” at which we change stuff in ways that are not backwards compatible to earlier versions. Once things are stable and we are looking at a real release, a versioning scheme will be in place to handle this.

* 2015-08-15: Increased the size of the token from 4 to 8 bytes. Protocol format has changed as a result. The old clients will fail to handle this correctly. Also, started using the Versions more correctly in the protocol.

# What is a DHT?

A distributed hash table is a mapping from *identities* which are 256 bit numbers to a list of pairs, `[{IP, Port}]` on which the identity has been registered. The table is *distributed* by having a large number of nodes store small parts of the mapping each. Also, each node keeps a partial routing table in order to be able to find values.

Note the DHT, much like DNS doesn't interpret what the identity is. It just maps that identity onto the IP/Port endpoints. That is, you have to write your own protocol once you know where an identity is registered.

Also, the protocol makes no security guarantees. Anyone can claim to store a given ID. It is recommended clients have some way to verify that indeed, the other end stores the correct value for the ID. For instance, one can run `ID = crypto:sha(256, Val)` on a claimed value to verify that it is correct, as long as the value does not take too long to transfer. Another option is to store a Public key as the identity and then challenging the target end to verify the correct key, for instance by use of a protocol like CurveCP.

The implemented DHT has the following properties:

* Multiple peers can store the same identity. In that case, each peer is reflected in the table.
* Protocol agnostic, you are encouraged to do your own protocol, security checking and blacklisting of peers.
* Insertion is fast, but deletion can take up to one hour because it is based on timeouts. If a node disappears, it can take up to one hour before its entries are removed as well.
* Scalability is in millions of nodes.
* Storage is *probalistic*. An entry is stored at 8 nodes, and if all 8 nodes disappear, that entry will be lost for up to 45 hours, before it is reinserted in a refresh.

# Using the implementation:

The implementation supports 3 high-level commands, which together with two low-level commands is enough to run the DHT from scratch. Say you have just started a new DHT node:

	application:ensure_all_started(dht)
	
Then, in order to make the DHT part of swarm, you must know at least one node in the swarm. How to obtain the nodes it outside of the scope of the DHT application currently. One you know about a couple of nodes, you can ping them to insert them into the DHT routing table:

	[dht:ping({IP, Port}) || {IP, Port} <- Peers]
	
Then, in order to populate the routing table quickly, execute a find node search on your own randomly generated ID:

	Self = dht:node_id(),
	dht_search:run(find_node, Self).
	
At this point, we are part of the swarm, and can start using it. Say we want to say that ID 456 are present on our node, port 3000. We then execute:

	dht:enter(456, 3000)
	
and now the DHT tracks that association. If we later want to rid ourselves of the association, we use

	dht:delete(456)
	
Finally, other nodes can find the association by executing a lookup routine:

	[{IP, 3000}] = dht:lookup(456)
	
where IP is the IP address the node is using to send UDP packets.

# Code layout and how the DHT works

In general, we follow the [Kademlia](http://pdos.csail.mit.edu/~petar/papers/maymounkov-kademlia-lncs.pdf) hash table implementation. But the implementation details of this code is down below. The key take-away is that in order to implement Kademlia in Erlang, you have to come up with a working process model.

The system supports 4 low-level commands:

* `PING({IP, Port})`—Ask a node if it is alive
* `FIND_NODE({IP, Port}, NodeID)`—Ask a peer routing table about information on `NodeID`.
* `FIND_VALUE({IP, Port}, ID)`—Ask a peer about knowledge about a stored value `ID`. May return either information about that value, or a set of nodes who are likely to know more about it. Will also return a temporary token to be used in subsequent `STORE` operations.
* `STORE({IP, Port}, Token, ID, Port)`—If the current node is on IP-address `NodeIP`, then call a peer at `{IP, Port}` to associate `ID => {NodeIP, Port}`. The `Token` provides proof we recently executed a `FIND_VALUE` call to the peer.

These are supported by a number of process groups, which we describe in the following:

## dht_metric.erl

The `dht_metric` module is a library, not a process. It implements the metric space in which the DHT operates:

The DHT operates on an identity-space which are 256 bit integers. If `X` and `Y` are IDs, then `X xor Y` forms a [metric](https://en.wikipedia.org/wiki/Metric_(mathematics)), or distance-function, over the space. Each node in the DHT swarm has an ID, and nodes are close to each other if the distance is small.

Every ID you wish to store is a 256 bit integer. Likewise, they are mapped into the space with the nodes. Nodes which are “close” to a stored ID tracks who is currently providing service for that ID.

## dht_net.erl, dht_proto.erl

The DHT communicates via a simple binary protocol that has been built loosely on the BitTorrent protocol. However, the protocol has been changed completely from BitTorrent and has no resemblance to the original protocol whatsoever. The protocol encoding/decoding scheme is implemented in `dht_proto` and can be changed later on if necessary by adding a specific 8 byte random header to messages.

All of the network stack is handled by `dht_net`. This gen_server runs two tasks: incoming requests and outgoing requests.

For incoming requests, a handler process is spawned to handle that particular query. Once it knows about an answer, it invokes `dht_net` again to send out the response. For outgoing requests, the network gen_server uses `noreply` to block the caller until either timeout or until a response comes back for a request. It then unblocks the caller. In short, `dht_net` multiplexes the network.

The network protocol uses UDP. Currently, we don't believe packets will be large enough to mess with the MTU size of the IP stack, but we may be wrong.

Storing data at another node is predicated on a random token. Technically, the random token is hashed with the IP address of the peer in order to produce a unique token for that peer. If the peer wants to store data it has to present that token to prove it has recently executed a search and hit the node. It provides some security against forged stores of data at random peers. The random token is cycled once every minute to make sure there is some progress and a peer can't reuse a token forever.

The network protocol provides no additional security. In particular, there is currently no provision for blacklisting of talkative peers, no storage limit per node, no security handshake, etc.

## dht_state.erl, dht_routing_meta.erl, dht_routing_table.erl

The code in `dht_state` runs the routing table state of the system. To do so, it uses the `dht_routing_table` code to maintain the routing table, and uses the `dht_routing_meta` code to handle meta-data about nodes in the table.

Imagine a binary tree based on the digital bit-pattern of a 256 bit number. A `0` means “follow the left child” whereas a `1` means “follow the right child” in the tree. Since each node has a 256 bit ID, the NodeID, it sits somewhere in this tree. The full tree is the full routing table for the system, but in general this is a very large tree containing all nodes currently present in the system. Since there can be millions of nodes, it is not feasible to store the full routing table in each node. Hence, they opt for partial storage.

If you follow the path from the node's NodeID to the root of the tree, you follow a “spine” in the tree. At each node in the spine, there will be a child which leads down to our NodeID. The other child would lead to other parts of the routing table, but the routing table stores at most 8 such nodes in a “bucket”. Hence, the partial routing table is a spine of nodes, with buckets hanging on every path we don't take toward our own NodeID. This is what the routing table code stores.

For each node, we keep meta-data about that node: when we last successfully contacted it, how many times requests failed to reach it, and if we know it answers our queries. The latter is because many nodes are firewalled, so they can perform requests to other nodes, but you can't contact them yourself. Such nodes are not interesting to the routing table.

Every time a node is succesfully handled by the network code, it pings the state code with an update. This can then impact the routing table:

* If the node belongs to a bucket which has less than 8 nodes, it is inserted.
* If the node belongs into a full bucket, and there are nodes in the bucket which we haven't talked with for 15 minutes, we try to ping those nodes. If they fail to respond, we replace the bad node with the new one. This ensures the table tracks stable nodes over time.
* If the node belongs into a full bucket with nodes that we know are bad, we replace the bad one with the new node in hope it is better.

Periodically, every 15 minutes, we also check each bucket. If no nodes in the bucket has had any activity in the time-frame, we pick a random node in the bucket and asks it of its local nodes. For each node it returns, we try to insert those into the table. This ensures the bucket is somewhat full—even in the case the node is behind a firewall. Most nodes in the swarm which talk regularly will never hit these timers in practice.

We make a distinction between nodes which are reachable because they answered a query from us, and those where we answer a query for them. The rule is that refreshing of nodes can only happen if we have at some point had a successful reachable query to that node. And after this, then the node is refreshed even on non-reachable responses back to that node.

When the system stops, the routing table dumps its state to disk, but the meta-data is thrown out. The system thus starts in a state where it has to reconstruct information about nodes in its table, but since we don't know for how long we have been down, this is a fair trade-off.

## dht_store.erl

The store keeps a table mapping an ID to a IP/Port pair for other nodes are kept in the store. It is periodically collected for entries which are older than 1 hour. Thus, clients who wish a permanent entry needs to refresh it before one hour.

## dht_track.erl

The tracker is the natural dual counterpart to the store. It keeps mappings present in the DHT for a node by periodically refreshing them every 45 minutes. Thus, users of the DHT doesn't have to worry about refreshing nodes.

## Top level: dht.erl, dht_search.erl

The code here is not a process, but merely a library which is used by the code to perform recursive searches on top of the system. That is, the above implement the 4 major low-level commands, and this library uses them to handle  the DHT by combining them into useful high-level commands.

The search code implements the recursive nature of queries on a partial routing table. A search for a target ID or NodeID starts by using your own partial routing table to find peers close to the target. You then ask those nodes for the knowledge in their partial routing table. The returned nodes are then queried by yourself in order to hop a step closer to the target. This recursion continues until either the target is found, or we get as close as we can.


# Testing the DHT (example)

This section describes how to use the DHT before we have a bootstrap process into the system. The system is early alpha, so things might not work entirely as expected. I'm interested in any kind of error you see when trying to run this.

DHTs are learners algorithms. They learn about other peers when they communicate with other peers. If they know of no peers, the question is how one manages to start out. Usually one requests a number of bootstrap nodes and injects those blindly into the DHTs routing table at the start of the system. But a smarter way, when toying around, is just to ping a couple of other nodes which runs the DHT code. Once the DHT has run for a while, it will remember its routing table on disk, so then it should be able to start from the on-disk state.

Nodes needs to be “reachable” which means there are no firewall on the peer which makes it unable to respond.

To start out, set a port and start the DHT code:

	application:load(dht),
	application:set_env(dht, port, 1729),
	application:ensure_all_started(dht).
	
Do this on all nodes for which you want to run the DHT. If testing locally, you can pick different port numbers, but you probably also want to set the state file on disk differently in that case.

Ping the other node:

	dht:ping({{192,168,1,123}, 1729}).
	
At this point, the two nodes ought to know about each other. Then you can proceed to use the DHT:

	dht:enter(ID, Port).
	
will make the DHT remember that the entry identified by `ID` can be obtained on the IP of this node, on `Port`. A good way
to get at `ID` for a value `Value` is simply to call `ID = crypto:hash(sha256, Value)`. To look up a handler for an ID, use

	3> dht:lookup(ID).
	[{{172,16,1,200},12345}]
	
which means `ID` can be found at `{172,16,1,200}` on port `12345`. The DHT does not specify the protocol to use there. But one could just define it is HTTP/1.1 and you then request `http://172.16.1.200:12345/ID`. It could also be another protocol, at your leisure.

## QuickCheck

The "research project" which is being done in this project is to provide a full QuickCheck model of every part of the DHT code. This work has already uncovered numerous grave errors and mistakes in the original etorrent code base, to the point where I'm wondering if this code even worked appropriately in the first place.

Hence, the modeling work continues. It is slowly moving, because you often need to do successive refinement on the knowledge you have as you go along. On the other hand, the parts which have been checked are likely to be formally correct. Far more than any other project.

The current effort is centered around the construction of the top level binding code, that makes everything fit together. This code has not been handled by a QuickCheck model yet, however. What *has* been handled already though, is all the low-level parts: network code, routing stable state code and so on.

# TODO List:

* Cover the remaining parts of the code base
* Consider the construction of a false “universe” so we can simulate what the rest of the world is storing at a given point in time.
* Simple tests on a 1-node network should behave as expected
