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
	}
}

private bool matchPluginUrl(URL url) {
	string path = url.path.toString;

	enum len = "/principals/".length;

	if(path.length >= len && path[0..len] == "/principals/")
		return true;

	return false;
}

class ACLDavResourcePlugin : ACLDavProperties, IDavResourcePlugin {

	string currentUserPrincipal(DavResource resource) {
		if(matchPluginUrl(resource.url))
			return "/principals/" ~ resource.username;

		throw new DavException(HTTPStatus.notFound, "not found");
	}

	string principalURL(DavResource resource) {
		if(matchPluginUrl(resource.url))
			return "/principals/" ~ resource.username;

		throw new DavException(HTTPStatus.notFound, "not found");
	}

	string[] principalCollectionSet(DavResource resource) {
		if(matchPluginUrl(resource.url))
			return [ "/principals/" ];

		throw new DavException(HTTPStatus.notFound, "not found");
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
		if(matchPluginUrl(resource.url) && hasDavInterfaceProperty!ACLDavProperties(name))
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
		if(canGetProperty(resource, name))
			return getDavInterfaceProperty!ACLDavProperties(name, this, resource);

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
			return "ResourceBasicProperties";
		}
	}
}

class ACLDavPlugin : IDavPlugin {

	private IDav _dav;

	this(IDav dav) {
		_dav = dav;
	}

	bool exists(URL url, string username) {
		return false;
	}

	bool canCreateCollection(URL url, string username) {
		return false;
	}

	bool canCreateResource(URL url, string username) {
		return false;
	}

	void removeResource(URL url, string username) {
		throw new DavException(HTTPStatus.internalServerError, "Can't remove resource.");
	}

	DavResource getResource(URL url, string username) {
		throw new DavException(HTTPStatus.internalServerError, "Can't get resource.");
	}

	DavResource createCollection(URL url, string username) {
		throw new DavException(HTTPStatus.internalServerError, "Can't create collection.");
	}

	DavResource createResource(URL url, string username) {
		throw new DavException(HTTPStatus.internalServerError, "Can't create resource.");
	}

	void bindResourcePlugins(ref DavResource resource) {
		resource.registerPlugin(new ACLDavResourcePlugin);
	}

	@property {
		IDav dav() {
			return _dav;
		}

		string name() {
			return "ACLDavPlugin";
		}

		string[] support(URL url, string username) {
			if(matchPluginUrl(url))
				return [ "access-control" ];

			return [];
		}
	}

}
