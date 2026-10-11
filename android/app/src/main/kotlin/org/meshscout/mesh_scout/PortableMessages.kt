package org.meshscout.mesh_scout
/** Portable history excludes live delivery tags and internal raw recovery checkpoints. */
object PortableMessages {
    private val fields = setOf("body", "peer", "radio", "status", "time", "outgoing", "unread")
    fun sanitize(input: Map<String, Any>): Map<String, Any> = input.filterKeys { it in fields }
}
