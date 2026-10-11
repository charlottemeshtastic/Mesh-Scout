package org.meshscout.mesh_scout

import org.junit.Assert.*
import org.junit.Test

class GpxRouteTest {
    private fun document(content: String) = "<gpx version='1.1' xmlns='http://www.topografix.com/GPX/1/1'>$content</gpx>"
    private val pair = "<trkpt lat='35' lon='-80'><time>2026-01-01T00:00:00Z</time></trkpt><trkpt lat='36' lon='-81'/>"
    private fun rejects(text: String) {
        try { GpxRoute.parse(text); fail("Expected invalid GPX rejection") } catch (_: Exception) { }
    }
    @Test fun readsTrackAndRouteAsLongitudeLatitude() {
        assertEquals(listOf(listOf(-80.0, 35.0), listOf(-81.0, 36.0)), GpxRoute.parse(document("<trk><trkseg>$pair</trkseg></trk>")))
        assertEquals(2, GpxRoute.parse(document("<rte>${pair.replace("trkpt", "rtept")}</rte>")).size)
    }
    @Test fun rejectsDisjointSegmentsAndInvalidCoordinates() {
        rejects(document("<trk><trkseg>$pair</trkseg><trkseg>$pair</trkseg></trk>"))
        rejects(document("<trk><trkseg>${pair.replace("lat='35'", "lat='NaN'")}</trkseg></trk>"))
        rejects(document("<trk><trkseg>${pair.replace("lat='35'", "lat='95'")}</trkseg></trk>"))
        rejects(document("<wpt lat='35' lon='-80'/><wpt lat='36' lon='-81'/>"))
    }
    @Test fun rejectsEntitiesForeignPointsMalformedAndOversizedRoutes() {
        rejects("<!DOCTYPE gpx [<!ENTITY x SYSTEM 'file:///private'>]>" + document("<rte>&x;</rte>"))
        rejects(document("<rte><rtept xmlns='urn:foreign' lat='35' lon='-80'/></rte>"))
        rejects(document("<trk><trkseg>$pair"))
        rejects(document("<rte>" + "<rtept lat='35' lon='-80'/>".repeat(10001) + "</rte>"))
    }
}
