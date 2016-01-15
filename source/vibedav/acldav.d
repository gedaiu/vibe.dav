/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 2 25, 2015
 * License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
 * Copyright: Public Domain
 */
module vibedav.acldav;

public import vibedav.base;

import vibe.core.file;
import vibe.inet.mimetypes;
import vibe.http.server;

interface ACLDavProperties {
	@property {
		/// rfc5397 - 3
		@ResourceProperty("current-user-principal", "DAV:")
		@ResourcePropertyTagText("href", "DAV:")
		string currentUserPrincipal(DavResource resource);

		/// rfc3744 - 4.2
		@ResourceProperty("principal-URL", "DAV:")
		@ResourcePropertyTagText("href", "DAV:")
		string principalURL(DavResource resource);

		/// rfc3744 - 5.8
		@ResourceProperty("principal-collection-set", "DAV:")
		@ResourcePropertyTagText("href", "DAV:")
		string[] principalCollectionSet(DavResource resource);

		@ResourceProperty("owner", "DAV:")
		@ResourcePropertyTagText("href", "DAV:")
		string owner(DavResource resource);
	}
}

private bool matchPluginUrl(Path path) {
	string strPath = path.toString;
	enum len = "principals/".length;

	return strPath.length >= len && strPath[0..len] == "principals/";
}

class ACLDavResourcePlugin : ACLDavProperties, IDavResourcePlugin, IDavReportSetProperties {

	string currentUserPrincipal(DavResource resource) {
		if(matchPluginUrl(resource.path))
			return "/" ~ resource.rootURL ~ "principals/" ~ resource.username ~ "/";

		throw new DavException(HTTPStatus.notFound, "not found");
	}

	string principalURL(DavResource resource) {
		if(matchPluginUrl(resource.path))
			return  "/" ~ resource.rootURL ~ "principals/" ~ resource.username ~ "/";

		throw new DavException(HTTPStatus.notFound, "not found");
	}

	string owner(DavResource resource) {
		return principalURL(resource);
	}

	string[] principalCollectionSet(DavResource resource) {
		if(matchPluginUrl(resource.path))
			return [  "/" ~ resource.rootURL ~ "principals/" ];

		throw new DavException(HTTPStatus.notFound, "not found");
	}

	string[] supportedReportSet(DavResource resource) {
		if(matchPluginUrl(resource.path))
			return ["expand-property:DAV:", "principal-property-search:DAV:", "principal-search-property-set:DAV:"];

		return [];
	}

	bool canSetContent(DavResource resource) {
		return false;
	}

	bool canGetStream(DavResource resource) {
		return false;
	}

	bool canSetProperty(DavResource resource, string name) {
		return false;
	}

	bool canRemoveProperty(DavResource resource, string name) {
		return false;
	}

	bool canGetProperty(DavResource resource, string name) {
		if(!matchPluginUrl(resource.path))
			return false;

		if(hasDavInterfaceProperty!ACLDavProperties(name))
			return true;

		if(hasDavInterfaceProperty!IDavReportSetProperties(name))
			return true;

		return false;
	}

	bool[string] getChildren(DavResource resource) {
		bool[string] list;
		return list;
	}

	void setContent(DavResource resource, const ubyte[] content) {
		throw new DavException(HTTPStatus.internalServerError, "Can't set content.");
	}

	void setContent(DavResource resource, InputStream content, ulong size) {
		throw new DavException(HTTPStatus.internalServerError, "Can't set content.");
	}

	InputStream stream(DavResource resource) {
		throw new DavException(HTTPStatus.internalServerError, "Can't get stream.");
	}

	void copyPropertiesTo(URL source, URL destination) { }

	DavProp property(DavResource resource, string name) {
		if(!matchPluginUrl(resource.path))
			throw new DavException(HTTPStatus.internalServerError, "Can't get property.");

		if(hasDavInterfaceProperty!ACLDavProperties(name))
			return getDavInterfaceProperty!ACLDavProperties(name, this, resource);

		if(hasDavInterfaceProperty!IDavReportSetProperties(name))
			return getDavInterfaceProperty!IDavReportSetProperties(name, this, resource);

		throw new DavException(HTTPStatus.internalServerError, "Can't get property.");
	}

	HTTPStatus setProperty(DavResource resource, string name, DavProp prop) {
		throw new DavException(HTTPStatus.internalServerError, "Can't set property.");
	}

	HTTPStatus removeProperty(DavResource resource, string name) {
		throw new DavException(HTTPStatus.internalServerError, "Can't remove property.");
	}

	@property {
		string name() {
			return "ACLDavResourcePlugin";
		}
	}
}

class ACLDavPlugin : BaseDavPlugin {

	private IDav _dav;

	this(IDav dav) {
		super(dav);
	}

	override void bindResourcePlugins(DavResource resource) {
		resource.registerPlugin(new ACLDavResourcePlugin);
	}

	@property {
		string name() {
			return "ACLDavPlugin";
		}

		override string[] support(URL url, string username) {
			return matchPluginUrl(dav.path(url)) ? [ "access-control" ] : [];
		}
	}
}
