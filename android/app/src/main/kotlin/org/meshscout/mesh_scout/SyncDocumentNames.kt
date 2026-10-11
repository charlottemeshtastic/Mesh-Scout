package org.meshscout.mesh_scout

/** Only committed snapshots participate; temporary files never hide valid data. */
object SyncDocumentNames {
    data class Entry(val name: String, val actor: String, val sequence: Long)
    private val pattern = Regex("meshscout-([a-f0-9]{32})-([0-9]{1,16})\\.mssync")
    fun parse(name: String): Entry? {
        val match = pattern.matchEntire(name) ?: return null
        val sequence = match.groupValues[2].toLong()
        if (sequence !in 1..9007199254740000L) return null
        return Entry(name, match.groupValues[1], sequence)
    }
    fun latest(entries: List<Entry>): List<Entry> {
        require(entries.map { it.actor to it.sequence }.toSet().size == entries.size) { "Duplicate sync sequence" }
        val groups = entries.groupBy { it.actor }; require(groups.size <= 8)
        return groups.values.map { rows -> rows.maxBy { it.sequence } }
    }
    fun retired(entries: List<Entry>, own: String): List<Entry> =
        entries.filter { it.actor == own }.sortedByDescending { it.sequence }.drop(2)
}
