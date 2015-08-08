# dht — Distributed Hash Table for Erlang

The `dht` application implements a Distributed Hash Table for Erlang. It is excised from the etorrent application in order to make it possible to use it without using the rest of etorrent.

The code is highly rewritten by now. There are few traces left of the original code base. The reason for the partial rewrite was to support a full QuickCheck model, so code was changed in order to make certain parts easier to handle from a formal point of view.

## What is a DHT?

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
