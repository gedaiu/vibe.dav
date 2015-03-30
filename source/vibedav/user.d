/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 3 22, 2015
 * License: Subject to the	 terms of the MIT license, as written in the included LICENSE.txt file.
 * Copyright: Public Domain
 */
module vibedav.user;

import vibedav.prop;


interface IDavUserPropertyAccess {

	/// Helper to get property name
	///
	/// eg. when name is principal-URL:DAV: the value
	/// of principalURL() is returned
	DavProp property(string name);
	pure bool hasProperty(string name);
}

interface IDavUser: IDavUserPropertyAccess, IDavBaseUser {

}

interface IDavBaseUser {
	pure {
		@property {
			/// rfc5397 - 3
			@ResourceProperty("current-user-principal", "DAV:")
			@ResourcePropertyTagText("href", "DAV:")
			string currentUserPrincipal();

			/// rfc3744 - 4.2
			@ResourceProperty("principal-URL", "DAV:")
			@ResourcePropertyTagText("href", "DAV:")
			string principalURL();

			/// rfc3744 - 5.8
			@ResourceProperty("principal-collection-set", "DAV:")
			@ResourcePropertyTagText("href", "DAV:")
			string[] principalCollectionSet();
		}
	}
}



interface ICalDavUser : IDavBaseUser {
	@property pure {

		/// rfc4791 - 6.2.1
		@ResourceProperty("calendar-home-set", "urn:ietf:params:xml:ns:caldav")
		@ResourcePropertyTagText("href", "DAV:")
		string[] calendarHomeSet();

		///rfc6638 - 2.1.1
		@ResourceProperty("schedule-outbox-URL", "urn:ietf:params:xml:ns:caldav")
		@ResourcePropertyTagText("href", "DAV:")
		string scheduleOutboxURL();

		/// rfc6638 - 2.2.1
		@ResourceProperty("schedule-inbox-URL", "urn:ietf:params:xml:ns:caldav")
		@ResourcePropertyTagText("href", "DAV:")
		string scheduleInboxURL();

		/// rfc6638 - 2.4.1
		@ResourceProperty("calendar-user-address-set", "urn:ietf:params:xml:ns:caldav")
		@ResourcePropertyTagText("href", "DAV:")
		string[] calendarUserAddressSet();
	}
}

interface IDavUserCollection {
	pure IDavUser GetDavUser(string name);
}
