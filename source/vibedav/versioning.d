/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 4 14, 2015
 * License: Subject to the	 terms of the MIT license, as written in the included LICENSE.txt file.
 * Copyright: Public Domain
 */
module vibedav.versioning;

import vibedav.davresource;

interface IVersioningCollectionProperties {

	@property {

		@ResourcePropertyLevelTagText("supported-report", "report", "DAV:")
		@ResourceProperty("supported-report-set", "DAV:")
		string[] supportedReportSet();
	}
}
