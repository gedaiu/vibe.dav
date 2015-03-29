/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 3 22, 2015
 * License: Subject to the	 terms of the MIT license, as written in the included LICENSE.txt file.
 * Copyright: Public Domain
 */
module vibedav.user;

import vibedav.prop;

interface IDavUser {
	pure {
		@property {
			/// rfc5397 - 3
			string currentUserPrincipal();

			/// rfc3744 - 4.2
			string principalURL();

			/// rfc3744 - 5.8
			string[] principalCollectionSet();
		}

		/// Helper to get property name
		///
		/// eg. when name is principal-URL:DAV: the value
		/// of principalURL() is returned
		string[][string] property(string name);
		bool hasProperty(string name);
	}
}

interface ICalDavUser : IDavUser {
	@property pure {

		/// rfc4791 - 6.2.1
		string[] calendarHomeSet();

		///rfc6638 - 2.1.1
		string scheduleOutboxURL();

		/// rfc6638 - 2.2.1
		string scheduleInboxURL();

		/// rfc6638 - 2.4.1
		string[] calendarUserAddressSet();
	}
}

interface IDavUserCollection {
	pure IDavUser GetDavUser(string name);
}
