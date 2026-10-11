package org.meshscout.mesh_scout

import org.junit.Assert.*
import org.junit.Test

class SyncDocumentNamesTest {
    private val a = "a".repeat(32)
    private val b = "b".repeat(32)
    private fun entry(actor: String, sequence: Long) = SyncDocumentNames.parse("meshscout-$actor-$sequence.mssync")!!
    @Test fun excludesPendingAndUnrelatedOrInvalidDocuments() {
        assertNull(SyncDocumentNames.parse("meshscout-$a-1.pending"))
        assertNull(SyncDocumentNames.parse("other-backup.mssync"))
        assertNull(SyncDocumentNames.parse("meshscout-$a-0.mssync"))
        assertNull(SyncDocumentNames.parse("meshscout-$a-9999999999999999.mssync"))
    }
    @Test fun selectsLatestPerDeviceWithoutDependingOnListingOrder() {
        val rows = listOf(entry(a, 2), entry(b, 5), entry(a, 1), entry(b, 3))
        assertEquals(setOf(entry(a, 2), entry(b, 5)), SyncDocumentNames.latest(rows).toSet())
        assertEquals(SyncDocumentNames.latest(rows).toSet(), SyncDocumentNames.latest(rows.reversed()).toSet())
    }
    @Test fun prunesOnlyOwnOldSnapshotsAndKeepsTwo() {
        val rows = listOf(entry(a, 1), entry(a, 2), entry(a, 3), entry(b, 1))
        assertEquals(listOf(entry(a, 1)), SyncDocumentNames.retired(rows, a))
    }
    @Test fun duplicateVersionsFailClosed() {
        try { SyncDocumentNames.latest(listOf(entry(a, 1), entry(a, 1))); fail("Expected rejection") }
        catch (_: IllegalArgumentException) { }
    }
}
