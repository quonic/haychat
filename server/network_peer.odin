package server

import "../common"
import "core:crypto/ecdh"
import "core:log"
import "core:net"
import "core:sync"
import "vendor:ENet"

// ChannelState tracks the state of a channel for a peer
ChannelState :: struct {
	status:       ChannelStatus,
	rateLimit:    u32, // bytes/sec, 0 = unlimited
	codecQuality: u8, // 0-100 for audio/video quality
	errorReason:  string, // Set if status = Error
}

// ChannelStatus represents the operational status of a channel
ChannelStatus :: enum u8 {
	None = 0,
	Active,
	Paused,
	Error,
}

NetworkPeerSession :: struct {
	transport:                 common.TransportState,
	clientIdentityPublicKey:   common.IdentityPublicKeyBytes,
	clientEphemeralPublicKey:  common.KeyExchangePublicKeyBytes,
	serverIdentityPublicKey:   common.IdentityPublicKeyBytes,
	serverEphemeralPrivateKey: ecdh.Private_Key,
	serverEphemeralPublicKey:  common.KeyExchangePublicKeyBytes,
	sessionID:                 common.SessionID,
	authChallenge:             common.AuthChallengeBytes,
	allowRegistration:         bool,
	isAuthenticated:           bool,
}

NetworkPeerSession_init :: proc() -> NetworkPeerSession {
	return NetworkPeerSession {
		transport = common.TransportState_init(.Server),
		allowRegistration = true,
	}
}

// NetworkPeer represents a connected client peer
NetworkPeer :: struct {
	id:             u32,
	address:        ENet.Address,
	activeChannels: [NetworkChannel]ChannelState, // Rich channel state per channel
	session:        NetworkPeerSession,
}

// PeerManager manages all connected peers with thread-safe access
PeerManager :: struct {
	peers:      map[u32]NetworkPeer,
	nextPeerId: u32,
	mutex:      sync.Mutex,
}

// PeerManager_init initializes a new PeerManager
PeerManager_init :: proc() -> PeerManager {
	return PeerManager{peers = make(map[u32]NetworkPeer), nextPeerId = 1}
}

// PeerManager_allocateID generates the next sequential peer ID with thread-safe access
PeerManager_allocateID :: proc(pm: ^PeerManager) -> u32 {
	sync.mutex_lock(&pm.mutex)
	defer sync.mutex_unlock(&pm.mutex)

	id := pm.nextPeerId
	pm.nextPeerId += 1

	return id
}

// PeerManager_addPeer adds a new peer to the manager
PeerManager_addPeer :: proc(pm: ^PeerManager, peer: NetworkPeer) -> bool {
	sync.mutex_lock(&pm.mutex)
	defer sync.mutex_unlock(&pm.mutex)

	if peer.id in pm.peers {
		log.warnf("Attempted to add duplicate peer ID: %d", peer.id)
		return false
	}

	pm.peers[peer.id] = peer
	return true
}

// PeerManager_removePeer removes a peer from the manager
PeerManager_removePeer :: proc(pm: ^PeerManager, peerId: u32) -> bool {
	sync.mutex_lock(&pm.mutex)
	defer sync.mutex_unlock(&pm.mutex)

	if peerId in pm.peers {
		// Rebuild map without this key
		oldPeers := pm.peers
		pm.peers = make(map[u32]NetworkPeer)
		for id, peer in oldPeers {
			if id != peerId {
				pm.peers[id] = peer
			}
		}
		return true
	}

	return false
}

// PeerManager_getPeer retrieves a peer by ID (returns a copy)
PeerManager_getPeer :: proc(pm: ^PeerManager, peerId: u32) -> (NetworkPeer, bool) {
	sync.mutex_lock(&pm.mutex)
	defer sync.mutex_unlock(&pm.mutex)

	if peerId in pm.peers {
		return pm.peers[peerId], true
	}

	return {}, false
}

// PeerManager_getPeerCount returns the number of connected peers
PeerManager_getPeerCount :: proc(pm: ^PeerManager) -> int {
	sync.mutex_lock(&pm.mutex)
	defer sync.mutex_unlock(&pm.mutex)

	return len(pm.peers)
}

// PeerManager_getAllPeers returns a slice of all peer IDs (caller must delete)
PeerManager_getAllPeers :: proc(pm: ^PeerManager, allocator := context.allocator) -> []u32 {
	sync.mutex_lock(&pm.mutex)
	defer sync.mutex_unlock(&pm.mutex)

	peers := make([dynamic]u32, 0, len(pm.peers), context.allocator)
	for id in pm.peers {
		append(&peers, id)
	}

	return peers[:]
}

// PeerManager_deinit cleans up the PeerManager
PeerManager_deinit :: proc(pm: ^PeerManager) {
	sync.mutex_lock(&pm.mutex)
	defer sync.mutex_unlock(&pm.mutex)

	delete(pm.peers)
}

PeerManager_getSession :: proc(pm: ^PeerManager, peerId: u32) -> (NetworkPeerSession, bool) {
	sync.mutex_lock(&pm.mutex)
	defer sync.mutex_unlock(&pm.mutex)

	if peerId not_in pm.peers {
		return {}, false
	}

	return pm.peers[peerId].session, true
}

PeerManager_setSession :: proc(
	pm: ^PeerManager,
	peerId: u32,
	session: NetworkPeerSession,
) -> bool {
	sync.mutex_lock(&pm.mutex)
	defer sync.mutex_unlock(&pm.mutex)

	if peerId not_in pm.peers {
		return false
	}

	peer := pm.peers[peerId]
	peer.session = session
	pm.peers[peerId] = peer
	return true
}

// PeerManager_setChannelState sets the state of a channel for a peer
PeerManager_setChannelState :: proc(
	pm: ^PeerManager,
	peerId: u32,
	channel: NetworkChannel,
	state: ChannelState,
) -> bool {
	sync.mutex_lock(&pm.mutex)
	defer sync.mutex_unlock(&pm.mutex)

	if peerId not_in pm.peers {
		return false
	}

	peer := pm.peers[peerId]
	peer.activeChannels[channel] = state
	pm.peers[peerId] = peer

	return true
}

// PeerManager_getChannelState retrieves the state of a channel for a peer
PeerManager_getChannelState :: proc(
	pm: ^PeerManager,
	peerId: u32,
	channel: NetworkChannel,
) -> (
	ChannelState,
	bool,
) {
	sync.mutex_lock(&pm.mutex)
	defer sync.mutex_unlock(&pm.mutex)

	if peerId not_in pm.peers {
		return {}, false
	}

	return pm.peers[peerId].activeChannels[channel], true
}

// PeerManager_isChannelActive checks if a channel is active for a peer
PeerManager_isChannelActive :: proc(
	pm: ^PeerManager,
	peerId: u32,
	channel: NetworkChannel,
) -> bool {
	sync.mutex_lock(&pm.mutex)
	defer sync.mutex_unlock(&pm.mutex)

	if peerId not_in pm.peers {
		return false
	}

	return pm.peers[peerId].activeChannels[channel].status == .Active
}

// PeerManager_pauseChannel pauses a channel for a peer
PeerManager_pauseChannel :: proc(pm: ^PeerManager, peerId: u32, channel: NetworkChannel) -> bool {
	sync.mutex_lock(&pm.mutex)
	defer sync.mutex_unlock(&pm.mutex)

	if peerId not_in pm.peers {
		return false
	}

	peer := pm.peers[peerId]
	if peer.activeChannels[channel].status == .Active {
		peer.activeChannels[channel].status = .Paused
		pm.peers[peerId] = peer
		return true
	}

	return false
}

// PeerManager_resumeChannel resumes a paused channel for a peer
PeerManager_resumeChannel :: proc(pm: ^PeerManager, peerId: u32, channel: NetworkChannel) -> bool {
	sync.mutex_lock(&pm.mutex)
	defer sync.mutex_unlock(&pm.mutex)

	if peerId not_in pm.peers {
		return false
	}

	peer := pm.peers[peerId]
	if peer.activeChannels[channel].status == .Paused {
		peer.activeChannels[channel].status = .Active
		pm.peers[peerId] = peer
		return true
	}

	return false
}
