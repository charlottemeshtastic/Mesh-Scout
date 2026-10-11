package org.meshscout.mesh_scout
import org.junit.Assert.*
import org.junit.Test
class PortableMessagesTest {
    @Test fun portableHistoryExcludesInternalAndSecretFields() {
        val source=mapOf<String,Any>("body" to "hello", "radio" to "my radio", "unread" to true,
            "tag" to 42, "_checkpoint" to "raw transport frame", "secret" to "not portable")
        val result=PortableMessages.sanitize(source)
        assertEquals(setOf("body","radio","unread"),result.keys)
        assertEquals("hello",result["body"]);assertEquals(true,result["unread"])
        assertTrue(source.containsKey("tag"))
    }
}
