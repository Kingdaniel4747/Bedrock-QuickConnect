package de.quickconnect.app

import org.junit.Assert.*
import org.junit.Test

class ConnectionStateTest {
    @Test
    fun stopAndFailureAreInactive() {
        for (phase in Phase.entries) {
            assertEquals(phase != Phase.IDLE && phase != Phase.ERROR, ConnectionState(phase).active)
        }
    }

    @Test
    fun onlyNativeTransferEventReportsTheTransfer() {
        assertEquals(Phase.CONNECTED, reduceEvent("connected")?.first)
        assertEquals(Phase.TRANSFER, reduceEvent("transfer:example.com:19132")?.first)
        assertEquals(Phase.RELEASED, reduceEvent("released")?.first)
        assertNull(reduceEvent("success"))
    }

    @Test
    fun peerFailureKeepsDiscoveryAvailableAndListenerFailureStopsIt() {
        assertEquals(Phase.WAITING, reduceEvent("peer-error:timeout")?.first)
        assertEquals(Phase.ERROR to "socket closed", reduceEvent("error:socket closed"))
    }

    @Test
    fun onlyChangesToTheBoundWifiInvalidateTheSession() {
        assertFalse(wifiInvalidated(false, "192.168.0.10", null))
        assertFalse(wifiInvalidated(true, "192.168.0.10", "192.168.0.10"))
        assertTrue(wifiInvalidated(true, "192.168.0.10", "192.168.0.11"))
        assertTrue(wifiInvalidated(true, "192.168.0.10", null))
    }
}

