/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 4 23, 2015
 * License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
 * Copyright: Public Domain
 */
module vibedav.syncdav;

import std.datetime;

import vibedav.base;
import vibedav.davresource;
import vibe.core.file;

import vibe.http.server;


interface ISyncDavProperties {
	@property {

		/// rfc6578 - 4
		@ResourceProperty("sync-token", "DAV:")
		string syncToken(DavResource resource);
	}
}

interface ISyncDavReports {

	/// rfc6578 - 3.2
	@DavReport("sync-collection", "DAV:")
	void syncCollection(DavRequest request, DavResponse response);
}

class SyncDavDataPlugin : BaseDavResourcePlugin, ISyncDavProperties {

	private SyncDavPlugin _syncPlugin;

	this(SyncDavPlugin syncPlugin) {
		_syncPlugin = syncPlugin;
	}

	string syncToken(DavResource resource) {
		return SyncDavPlugin.prefix ~ _syncPlugin.currentChangeNr.to!string;
	}

	override {
		bool canGetProperty(DavResource resource, string name) {
			if(hasDavInterfaceProperty!ISyncDavProperties(name))
				return true;

			return false;
		}

		DavProp property(DavResource resource, string name) {
			if(hasDavInterfaceProperty!ISyncDavProperties(name))
				return getDavInterfaceProperty!ISyncDavProperties(name, this, resource);

			throw new DavException(HTTPStatus.internalServerError, "Can't get property.");
		}
	}

	@property
	string name() {
		return "SyncDavDataPlugin";
	}
}

// todo: add ISyncDavReports
class SyncDavPlugin : BaseDavPlugin, ISyncDavReports {
	enum string prefix = "http://vibedav/ns/sync/";

	struct Change {
		Path path;
		string type;
		SysTime time;
	}

	private {
		Change[] log;
		ulong changeNr = 1;
	}

	this(IDav dav) {
		super(dav);
	}

	protected {

		ulong getToken(DavProp[] syncTokenList) {
			if(syncTokenList.length == 0)
				return 0;

			if(syncTokenList[0].tagName != "sync-token")
				return 0;

			string value = syncTokenList[0].value;

			if(value.length == 0)
				return 0;

			if(value.length <= prefix.length)
				return 0;

			if(value[0..prefix.length] != prefix)
				return 0;

			value = value[prefix.length..$];

			try {
				return value.to!ulong;
			} catch(Exception e) {
				throw new DavException(HTTPStatus.internalServerError, "invalid sync-token");
			}
		}

		ulong getLevel(DavProp[] syncLevelList) {
			if(syncLevelList.length == 0)
				return 0;

			if(syncLevelList[0].name != "sync-level")
				return 0;

			try {
				return syncLevelList[0].value.to!ulong;
			} catch(Exception e) {
				throw new DavException(HTTPStatus.internalServerError, "invalid sync-level");
			}
		}

		bool[string] getChangesFrom(ulong token) {
			if(token > changeNr)
				throw new DavException(HTTPStatus.forbidden, "Invalid token.");

			bool[string] wasRemoved;

			foreach(i; token..changeNr-1) {
				auto change = log[i];

				wasRemoved[change.path.toString] = (change.type == "deleted");
			}

			return wasRemoved;
		}
	}

	void syncCollection(DavRequest request, DavResponse response) {
		response.mimeType = "application/xml";
		response.statusCode = HTTPStatus.multiStatus;
		auto reportData = request.content;

		bool[string] requestedProperties;
		HTTPStatus[string] responseCodes;

		foreach(name, p; reportData["sync-collection"]["prop"])
			requestedProperties[name] = true;

		auto syncTokenList = [ reportData["sync-collection"] ].getTagChilds("sync-token");
		auto syncLevelList = [ reportData["sync-collection"] ].getTagChilds("sync-level");

		ulong token = getToken(syncTokenList);
		ulong level = getLevel(syncLevelList);

		DavResource[] list;
		auto changes = getChangesFrom(token);

		foreach(string path, bool wasRemoved; changes) {
			if(wasRemoved) {
				responseCodes[path] = HTTPStatus.notFound;
			} else {
				list ~= _dav.getResource(URL(path), request.username);
			}
		}

		response.setPropContent(list, requestedProperties, responseCodes);
		response.flush;
	}

	override {
		bool hasReport(URL url, string username, string name) {

			if(hasDavReport!ISyncDavReports(name))
				return true;

			return false;
		}

		void report(DavRequest request, DavResponse response) {
			if(!hasDavReport!ISyncDavReports(request.content.reportName))
				throw new DavException(HTTPStatus.internalServerError, "Can't get report.");

			getDavReport!ISyncDavReports(this, request, response);
		}

		void bindResourcePlugins(DavResource resource) {
			if(resource.isCollection)
				resource.registerPlugin(new SyncDavDataPlugin(this));
		}

		void notice(string action, DavResource resource) {
			if(action == "created" || action == "deleted" || action == "changed") {
				changeNr++;
				log ~= Change(resource.url.path, action, Clock.currTime);
			}
		}
	}

	@property {
		ulong currentChangeNr() {
			return changeNr;
		}

		string name() {
			return "SyncDavPlugin";
		}
	}
}
