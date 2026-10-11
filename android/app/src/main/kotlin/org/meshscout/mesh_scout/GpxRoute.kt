package org.meshscout.mesh_scout

import java.io.StringReader
import javax.xml.parsers.SAXParserFactory
import org.xml.sax.Attributes
import org.xml.sax.InputSource
import org.xml.sax.SAXException
import org.xml.sax.helpers.DefaultHandler

/** Bounded planned geometry; no timestamps or coverage measurements are imported. */
object GpxRoute {
    fun parse(text: String): List<List<Double>> {
        require(text.toByteArray(Charsets.UTF_8).size <= 20 * 1024 * 1024) { "Route exceeds 20 MB" }
        // GPX does not need DTDs. Reject them before parsing on both Android and JVM.
        require(!Regex("<!\\s*(DOCTYPE|ENTITY)", RegexOption.IGNORE_CASE).containsMatchIn(text)) { "DTD/entity declarations are unsupported" }
        val points = mutableListOf<List<Double>>()
        val path = mutableListOf<String>()
        var namespace = ""
        var groups = 0
        val handler = object : DefaultHandler() {
            override fun resolveEntity(publicId: String?, systemId: String?): InputSource {
                throw SAXException("External entities are unsupported")
            }
            override fun startElement(uri: String, localName: String, qName: String, attributes: Attributes) {
                require(path.size < 64) { "XML nesting exceeds limit" }
                if (path.isEmpty()) {
                    require(localName == "gpx" && uri in listOf("", "http://www.topografix.com/GPX/1/0", "http://www.topografix.com/GPX/1/1")) { "Use GPX 1.0 or 1.1" }
                    require(attributes.getValue("version") in listOf("1.0", "1.1")) { "Use GPX 1.0 or 1.1" }
                    namespace = uri
                }
                val name = if (uri == namespace) localName else "foreign"
                path.add(name)
                if (path == listOf("gpx", "rte") || path == listOf("gpx", "trk", "trkseg")) {
                    groups++
                    require(groups == 1) { "Choose exactly one route or track segment; split separate segments first" }
                }
                if (path == listOf("gpx", "rte", "rtept") || path == listOf("gpx", "trk", "trkseg", "trkpt")) {
                    require(points.size < 10000) { "Use 2–10,000 route points" }
                    val lat = attributes.getValue("lat")?.toDoubleOrNull()
                    val lon = attributes.getValue("lon")?.toDoubleOrNull()
                    require(lat != null && lon != null && lat.isFinite() && lon.isFinite() && lat in -90.0..90.0 && lon in -180.0..180.0) { "Invalid WGS84 coordinates" }
                    points.add(listOf(lon, lat))
                }
            }
            override fun endElement(uri: String, localName: String, qName: String) { path.removeAt(path.lastIndex) }
        }
        val factory = SAXParserFactory.newInstance().apply { isNamespaceAware = true; isValidating = false }
        factory.newSAXParser().parse(InputSource(StringReader(text)), handler)
        require(groups == 1 && points.size >= 2) { "Use one route or track segment with 2–10,000 points" }
        return points
    }
}
