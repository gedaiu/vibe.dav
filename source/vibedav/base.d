/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 2 15, 2015
 * License: Subject to the	 terms of the MIT license, as written in the included LICENSE.txt file.
 * Copyright: Public Domain
 */
module vibedav.base;

public import vibedav.util;
public import vibedav.prop;

import vibe.core.log;
import vibe.core.file;
import vibe.inet.mimetypes;
import vibe.inet.message;
import vibe.http.server;
import vibe.http.fileserver;
import vibe.http.router : URLRouter;
import vibe.stream.operations;
import vibe.utils.dictionarylist;

import std.conv : to;
import std.algorithm;
import std.file;
import std.path;
import std.digest.md;
import std.datetime;
import std.string;
import std.stdio : writeln; //todo: remove this
import std.typecons;
import std.uri;
import std.uuid;

alias HeaderList = DictionaryList!(string, false, 32L);

string getHeaderValue(HeaderList headers, string name, string defaultValue = "") {

	string value = defaultValue;

	if(name !in headers && defaultValue == "")
		throw new DavException(HTTPStatus.internalServerError, "Can't find '"~name~"' in headers.");
	else
		value = headers.get(name, defaultValue);

	return value;
}

unittest {
	HeaderList list;
	list["key"] = "value";
	auto val = getHeaderValue(list, "key");
	assert(val == "value");
}

unittest {
	HeaderList list;
	auto val = getHeaderValue(list, "key", "default");
	assert(val == "default");
}

unittest {
	bool raised = false;

	try {
		HeaderList list;
		list["key"] = "value";
		getHeaderValue(list, "key1");
	} catch(DavException e) {
		raised = true;
	}

	assert(raised);
}

void enforce(string[] valid)(string value) {

}

string getHeader(string name)(HeaderList headers) {
	string value;

	static if(name == "Depth") {
		value = getHeaderValue(headers, name, "infinity");
		value.enforce!(["0", "1", "infinity"]);
	} else static if(name == "Overwrite") {
		value = getHeaderValue(headers, name, "F");
		value.enforce!(["T", "F"]);
	} else {
		value = getHeaderValue(headers, name);
	}

	return value;
}

class DavException : Exception {
	HTTPStatus status;
	string mime;

	///
	this(HTTPStatus status, string msg, string mime = "plain/text", string file = __FILE__, size_t line = __LINE__, Throwable next = null)
	{
		super(msg, file, line, next);
		this.status = status;
		this.mime = mime;
	}

	///
	this(HTTPStatus status, string msg, Throwable next, string mime = "plain/text", string file = __FILE__, size_t line = __LINE__)
	{
		super(msg, next, file, line);
		this.status = status;
		this.mime = mime;
	}
}

enum DavDepth : int {
	zero = 0,
	one = 1,
	infinity = 99
};

class DavLockInfo {

	enum Scope {
		exclusiveLock,
		sharedLock
	};

	Scope scopeLock;
	bool isWrite;
	string owner;
	SysTime timeout;
	DavResource root;
	string token;
	DavDepth depth;

	static DavLockInfo fromXML(DavProp node) {
		auto lock = new DavLockInfo;
		/*
		XmlNode[] xmlSharedScope = node.parseXPath("d:lockinfo/d:lockscope/d:shared") ~ node.parseXPath("lockinfo/lockscope/shared");
		XmlNode[] xmlExclusiveScope = node.parseXPath("d:lockinfo/d:lockscope/d:exclusive") ~ node.parseXPath("lockinfo/lockscope/exclusive");
		XmlNode[] xmlWriteType = node.parseXPath("d:lockinfo/d:locktype/d:write") ~ node.parseXPath("lockinfo/locktype/write");
		XmlNode[] xmlOwner = node.parseXPath("d:lockinfo/d:owner/d:href") ~ node.parseXPath("lockinfo/owner/href");

		if(xmlSharedScope.length == 1)
			lock.scopeLock = Scope.sharedLock;
		else if(xmlExclusiveScope.length == 1)
			lock.scopeLock = Scope.exclusiveLock;
		else
			throw new DavException(HTTPStatus.internalServerError, "Unknown lock.");

		if(xmlWriteType.length == 1)
			lock.isWrite = true;
		else
			lock.isWrite = false;

		if(xmlOwner.length == 1)
			lock.owner = xmlOwner[0].getInnerXML;

		lock.token = randomUUID.toString;*/

		return lock;
	}

	/// Set the timeout based on the request header
	void setTimeout(string timeoutHeader) {
		if(timeoutHeader.indexOf("Infinite") != -1) {
			timeout = SysTime.max;
			return;
		}

		auto secIndex = timeoutHeader.indexOf("Second-");
		if(secIndex != -1) {
			auto val = timeoutHeader[secIndex+7..$].to!int;
			timeout = Clock.currTime + dur!"seconds"(val);
			return;
		}

		throw new DavException(HTTPStatus.internalServerError, "Invalid timeout value");
	}

	override string toString() {
		string a = `<?xml version="1.0" encoding="utf-8" ?>`;
		a ~= `<D:prop xmlns:D="DAV:"><D:lockdiscovery><D:activelock>`;

		if(isWrite)
			a ~= `<D:locktype><D:write/></D:locktype>`;

		if(scopeLock == Scope.exclusiveLock)
			a ~= `<D:lockscope><D:exclusive/></D:lockscope>`;
		else if(scopeLock == Scope.sharedLock)
			a ~= `<D:lockscope><D:shared/></D:lockscope>`;

		if(depth == DavDepth.zero)
			a ~= `<D:depth>0</D:depth>`;
		else if(depth == DavDepth.infinity)
			a ~= `<D:depth>infinity</D:depth>`;

		if(owner != "")
			a ~= `<D:owner><D:href>`~owner~`</D:href></D:owner>`;

		if(timeout == SysTime.max)
			a ~= `<D:timeout>Infinite</D:timeout>`;
		else {
			long seconds = (timeout - Clock.currTime).total!"seconds";
			a ~= `<D:timeout>Second-` ~ seconds.to!string ~ `</D:timeout>`;
		}

		a ~= `<D:locktoken><D:href>urn:uuid:`~token~`</D:href></D:locktoken>`;

		a ~= `<D:lockroot><D:href>`~root.fullURL~`</D:href></D:lockroot>`;

		a ~= `</D:activelock></D:lockdiscovery></D:prop>`;

		return a;
	}
}

/// Represents a general DAV resource
class DavResource {
	string href;
	URL url;

	DavProp properties;

	HTTPStatus statusCode;
	bool isCollection;

	protected {
		Dav dav;
	}

	this(Dav dav, URL url) {
		this.dav = dav;
		this.url = url;

		string strUrl = url.toString;

		if(strUrl !in dav.resourcePropStorage) {
			dav.resourcePropStorage[strUrl] = new DavProp;
			dav.resourcePropStorage[strUrl].addNamespace("d", "DAV:");
		}

		this.properties = dav.resourcePropStorage[strUrl];
	}

	@property
	string name() {
		return href.baseName;
	}

	@property
	string fullURL() {
		return url.toString;
	}

	string propXmlString(bool[string] props = cast(bool[string])[]) {
		string str = `<d:href>` ~ url.to!string ~ `</d:href>`;
		str ~= `<d:propstat><d:prop>`;

		foreach(key, val; properties) {
			auto key1 = key.toLower;

			writeln("is ", key1, " in ", props, " ", key1 in props);

			bool add = true;
			if(props.length > 0 && (key1 in props) is null)
				add = false;

			if(add)
				str ~= val.toString;
		}

		if(props.length == 0 || (props.length > 0 && ("d:resourcetype" in props) !is null)) {
			if(isCollection)
				str ~= `<d:resourcetype><d:collection /></d:resourcetype>`;
			else
				str ~= `<d:resourcetype />`;
		}

		str ~= `</d:prop></d:propstat>`;
		str ~= `<d:status>HTTP/1.1 ` ~ statusCode.to!int.to!string ~ ` ` ~ httpStatusText(statusCode) ~ `</d:status>`;

		return str;
	}

	bool hasChild(Path path) {
		auto childList = getChildren;

		foreach(c; childList)
			if(c.href == path.to!string)
				return true;

		return false;
	}

	string propPatch(string content) {
		string description;
		string result = `<?xml version="1.0" encoding="utf-8" ?><d:multistatus xmlns:d="DAV:"><d:response>`;
		result ~= `<d:href>` ~ url.toString ~ `</d:href>`;

		auto document = parseXMLProp(content);

		//set properties
		auto setList = [document].getTagChilds("propertyupdate")
								 .getTagChilds("set")
								 .getTagChilds("prop");

		foreach(prop; setList) {
			foreach(string key, p; prop) {
				writeln("=>", key);
				properties[key] = p;
				result ~= `<d:propstat><d:prop>` ~ p.toString ~ `</d:prop>`;
				HTTPStatus status = HTTPStatus.ok;
				result ~= `<d:status>HTTP/1.1 ` ~ status.to!int.to!string ~ ` ` ~ status.to!string ~ `</d:status></d:propstat>`;
			}
		}

		/*
		//remove properties
		XmlNode[] removeList = document.parseXPath("d:propertyupdate/d:remove/d:prop") ~ document.parseXPath("propertyupdate/remove/prop");

		foreach(prop; removeList) {
			auto properties = prop.getChildren;

			foreach(p; properties) {
				string tagName = p.getName;
				string namespace = "";

				if(p.hasAttribute("xmlns"))
					namespace = p.getAttribute("xmlns");

				DavProp resProp;
				HTTPStatus status = HTTPStatus.ok;

				if(tagName in this.properties) {
					resProp = this.properties[tagName];
					resProp.value = "";
				} else {
					resProp = new DavProp(tagName, namespace);
					status = HTTPStatus.notFound;
				}

				//result ~= `<d:propstat><D:prop>` ~ resProp.toTag(tagName) ~ `</d:prop>`;

				try removeProp(tagName);
				catch (DavException e) {
					status = e.status;
					description ~= e.msg;
				}

				result ~= `<d:status>HTTP/1.1 ` ~ status.to!int.to!string ~ ` ` ~
								status.to!string ~ `</d:status></d:propstat>`;
			}
		}*/

		if(description != "")
			result ~= `<d:responsedescription>` ~ description ~ `</d:responsedescription>`;

		result ~= `</d:response></d:multistatus>`;

		string strUrl = url.toString;
		dav.resourcePropStorage[strUrl] = properties;

		return result;
	}

	void setProp(string name, DavProp prop) {
		properties[name] = prop;
		dav.resourcePropStorage[url.toString][name] = prop;
	}

	void removeProp(string name) {
		string urlStr = url.toString;

		if(name in properties) properties.remove(name);
		if(name in dav.resourcePropStorage[urlStr]) dav.resourcePropStorage[urlStr].remove(name);
	}


	void remove() {
		string strUrl = url.toString;

		if(strUrl in dav.resourcePropStorage)
			dav.resourcePropStorage.remove(strUrl);
	}

	HTTPStatus copy(URL destinationURL, bool overwrite = false) {
		dav.resourcePropStorage[destinationURL.toString] = dav.resourcePropStorage[url.toString];

		return HTTPStatus.ok;
	}

	abstract DavResource[] getChildren(ulong depth = 1);
	abstract HTTPStatus move(URL newPath, bool overwrite = false);
	abstract void setContent(const ubyte[] content);
}

/// A structure that helps to create the propfind response
struct PropfindResponse {

	DavResource list[];

	string toString() {
		bool[string] props;
		return toStringProps(props);
	}

	string toStringProps(bool[string] props) {
		string str = `<?xml version="1.0" encoding="UTF-8"?>`;
		str ~= `<d:multistatus xmlns:d="DAV:">`;

		foreach(res; list)
			str ~= `<d:response>` ~ res.propXmlString(props) ~ `</d:response>`;

		str ~= `</d:multistatus>`;

		return str;
	}
}

/// The main DAV protocol implementation
abstract class Dav {
	Path root;
	DavProp[string] resourcePropStorage;

	abstract DavResource getResource(URL url);
	abstract DavResource createCollection(URL url);
	abstract DavResource createProperty(URL url);

	void options(HTTPServerRequest req, HTTPServerResponse res) {
		string path = req.path;

		res.headers["Accept-Ranges"] = "bytes";
		res.headers["DAV"] = "1,2,3";
		res.headers["Allow"] = "OPTIONS, GET, HEAD, DELETE, PROPFIND, PUT, PROPPATCH, COPY, MOVE, LOCK, UNLOCK";
		res.headers["MS-Author-Via"] = "DAV";

		res.writeBody("", "text/plain");
	}

	private {
		DavDepth getDepth(HTTPServerRequest req) {

			if("depth" in req.headers) {
				string strDepth = getHeader!"Depth"(req.headers);

				if(strDepth == "0") return DavDepth.zero;
				if(strDepth == "1") return DavDepth.one;
			}

			return DavDepth.infinity;
		}

		bool[string] propList(DavProp document) {
			bool[string] list;

			auto properties = document["propfind"]["prop"];

			if(properties.length > 0)
				foreach(string key, p; properties)
					list[key.toLower] = true;

			writeln("LIST: ", list);

			return list;
		}

		string getRequestPath(HTTPServerRequest req) {
			string path = req.path;
			return path;
		}
	}

	DavResource getOrCreateResource(URL url, out int status) {
		DavResource resource;

		try {
			resource = getResource(url);
			status = HTTPStatus.ok;
		} catch (DavException e){
			if(e.status != HTTPStatus.notFound)
				throw e;

			resource = createProperty(url);
			status = HTTPStatus.created;
		}

		return resource;
	}

	void propfind(HTTPServerRequest req, HTTPServerResponse res) {
		string path = getRequestPath(req);
		int depth = getDepth(req).to!int;
		bool[string] properties;

		string requestXml = cast(string)req.bodyReader.readAllUTF8;

		if(requestXml.length > 0) {
			DavProp document;
			try document = requestXml.parseXMLProp;
			catch (DavPropException e)
				throw new DavException(HTTPStatus.badRequest, "Invalid xml body.");

			requestedProperties = propList(document);
		}

		auto selectedResource = getResource(req.fullURL);

		auto response = new PropfindResponse();
		response.list ~= selectedResource;

		if(selectedResource.isCollection)
			response.list ~= selectedResource.getChildren(depth);

		res.statusCode = HTTPStatus.multiStatus;

		if(requestedProperties.length == 0)
			res.writeBody(response.toString, "application/xml");
		else
			res.writeBody(response.toStringProps(requestedProperties), "application/xml");
	}

	void lock(HTTPServerRequest req, HTTPServerResponse res) {
		string path = getRequestPath(req);
		ulong depth = getDepth(req);
		string timeout = getHeader!"Timeout"(req.headers);

		bool[string] properties;

		string requestXml = cast(string)req.bodyReader.readAllUTF8;

		if(requestXml.length == 0)
			throw new DavException(HTTPStatus.internalServerError, "LOCK body expected.");

		DavProp document = requestXml.parseXMLProp;
		auto lockInfo = DavLockInfo.fromXML(document);

		auto resource = getOrCreateResource(req.fullURL, res.statusCode);

		lockInfo.setTimeout(timeout);
		lockInfo.root = resource;

		res.headers["Lock-Token"] = "<urn:uuid:"~lockInfo.token~">";

		res.writeBody(lockInfo.toString, "application/xml");
	}

	void get(HTTPServerRequest req, HTTPServerResponse res) {
		string path = getRequestPath(req);
		res.statusCode = HTTPStatus.ok;
		sendRawFile(req, res, root ~ path[1..$], new HTTPFileServerSettings);
	}

	void put(HTTPServerRequest req, HTTPServerResponse res) {
		string path = getRequestPath(req);

		DavResource resource = getOrCreateResource(req.fullURL, res.statusCode);

		auto content = req.bodyReader.readAll;
		resource.setContent(content);

		res.writeBody("", "text/plain");
	}

	void proppatch(HTTPServerRequest req, HTTPServerResponse res) {
		string path = getRequestPath(req);
		res.statusCode = HTTPStatus.ok;

		DavResource resource = getResource(req.fullURL);

		auto content = req.bodyReader.readAllUTF8;
		auto xmlString = resource.propPatch(content);

		res.writeBody(xmlString, "text/plain");
	}

	void mkcol(HTTPServerRequest req, HTTPServerResponse res) {
		string path = getRequestPath(req);

		auto content = req.bodyReader.readAll;
		if(content.length > 0)
			throw new DavException(HTTPStatus.unsupportedMediaType, "Body must be empty");

		try {
			getResource(req.fullURL.parentURL);
		} catch (DavException e) {
			if(e.status == HTTPStatus.notFound)
				throw new DavException(HTTPStatus.conflict, "Missing parent");
		}

		res.statusCode = HTTPStatus.created;
		createCollection(req.fullURL);
		res.writeBody("", "text/plain");
	}

	void remove(HTTPServerRequest req, HTTPServerResponse res) {
		string path = getRequestPath(req);

		res.statusCode = HTTPStatus.noContent;

		if(req.fullURL.anchor != "" || req.requestURL.indexOf("#") != -1)
			throw new DavException(HTTPStatus.conflict, "Missing parent");

		getResource(req.fullURL).remove();

		res.writeBody("", "text/plain");
	}

	void move(HTTPServerRequest req, HTTPServerResponse res) {
		string path = getRequestPath(req);

		auto selectedResource = getResource(req.fullURL);

		string destination = getHeader!"Destination"(req.headers);
		string overwrite = getHeader!"Overwrite"(req.headers);

		res.statusCode = selectedResource.move(URL(destination), overwrite == "T");

		res.writeBody("", "text/plain");
	}

	void copy(HTTPServerRequest req, HTTPServerResponse res) {
		string path = getRequestPath(req);

		auto selectedResource = getResource(req.fullURL);

		string destination = getHeader!"Destination"(req.headers);
		string overwrite = getHeader!"Overwrite"(req.headers);

		res.statusCode = selectedResource.copy(URL(destination), overwrite == "T");

		res.writeBody("", "text/plain");
	}
}


HTTPServerRequestDelegate serveDav(T : Dav)(Path path) {
	auto dav = new T;
	dav.root = path;

	void callback(HTTPServerRequest req, HTTPServerResponse res)
	{
		try {

			debug {
				if("X-Litmus" in req.headers) {
					writeln("\n\n\n");
					writeln(req.headers["X-Litmus"]);
					writeln("Method: ", req.method);
					writeln("==========================");
				}
			}

			if(req.method == HTTPMethod.OPTIONS) {
				dav.options(req, res);
			} else if(req.method == HTTPMethod.PROPFIND) {
				dav.propfind(req, res);
			} else if(req.method == HTTPMethod.GET) {
				dav.get(req, res);
			} else if(req.method == HTTPMethod.PUT) {
				dav.put(req, res);
			} else if(req.method == HTTPMethod.PROPPATCH) {
				dav.proppatch(req, res);
			} else if(req.method == HTTPMethod.LOCK) {
				dav.lock(req, res);
			} else if(req.method == HTTPMethod.MKCOL) {
				dav.mkcol(req, res);
			} else if(req.method == HTTPMethod.DELETE) {
				dav.remove(req, res);
			} else if(req.method == HTTPMethod.COPY) {
				dav.copy(req, res);
			} else if(req.method == HTTPMethod.MOVE) {
				dav.move(req, res);
			} else {
				res.statusCode = HTTPStatus.notImplemented;
				res.writeBody("", "text/plain");
			}
		} catch(DavException e) {
			writeln("ERROR:",e.status.to!int, "(", e.status, ") - ", e.msg);

			res.statusCode = e.status;
			res.writeBody(e.msg, e.mime);
		}

		writeln("SUCCESS:", res.statusCode.to!int, "(", res.statusCode, ")");
	}

	return &callback;
}
