/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 2 15, 2015
 * License: Subject to the	 terms of the MIT license, as written in the included LICENSE.txt file.
 * Copyright: Public Domain
 */

module vibedav.base;

public import vibedav.util;

import vibe.core.log;
import vibe.core.file;
import vibe.inet.mimetypes;
import vibe.inet.message;
import vibe.http.server;
import vibe.http.fileserver;
import vibe.http.router : URLRouter;
import vibe.stream.operations;
import vibe.utils.dictionarylist;

import kxml.xml;

import std.conv : to;
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

	static DavLockInfo fromXML(XmlNode node) {
		auto lock = new DavLockInfo;

		XmlNode[] xmlSharedScope = node.parseXPath("d:lockinfo/d:lockscope/d:shared");
		XmlNode[] xmlExclusiveScope = node.parseXPath("d:lockinfo/d:lockscope/d:exclusive");
		XmlNode[] xmlWriteType = node.parseXPath("d:lockinfo/d:locktype/d:write");
		XmlNode[] xmlOwner = node.parseXPath("d:lockinfo/d:owner/d:href");

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

		lock.token = randomUUID.toString;

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
	string[string] properties;
	HTTPStatus statusCode;
	bool isCollection;


	private Dav dav;

	this(Dav dav, URL url) {
		this.dav = dav;
		this.url = url;
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

			if(props.length == 0 || props.length > 0 && (key1 in props) !is null)
				str ~= `<` ~ key ~ `>` ~ val ~ `</` ~ key ~ `>`;
		}

		if(props.length == 0 || (props.length > 0 && ("d:resourcetype" in props) !is null)) {
			if(isCollection)
				str ~= `<d:resourcetype><d:collection /></d:resourcetype>`;
			else
				str ~= `<d:resourcetype />`;
		}

		str ~= `</d:prop></d:propstat>`;
		str ~= `<d:status>HTTP/1.1 ` ~ statusCode.to!string ~ ` ` ~ httpStatusText(statusCode) ~ `</d:status>`;

		return str;
	}

	bool hasChild(Path path) {
		auto childList = getChildren;

		foreach(c; childList)
			if(c.href == path.to!string)
				return true;

		return false;
	}

	abstract DavResource[] getChildren(ulong depth = 1);
	abstract void remove();
	abstract void move(URL newPath, bool overwrite = false);
	abstract void copy(URL destinationURL, bool overwrite = false);
	abstract void setContent(const ubyte[] content);
}

/// Represents a file or directory DAV resource
final class DavFileResource : DavResource {
	private immutable {
		Path resPath;
		Path fileRoot;
		Path filePath;
	}

	this(Dav dav, Path root, URL url) {
		super(dav, url);

		auto path = url.path;

		path.normalize;
		root.normalize;

		logTrace("create DAV file resource %s %s", root , path);

		resPath = path;
		fileRoot = root;
		filePath = root ~ path.toString[1..$];

		FileInfo dirent;
		auto pathstr = filePath.toNativeString();

		try dirent = getFileInfo(pathstr);
		catch(Exception) {
			throw new HTTPStatusException(HTTPStatus.InternalServerError,
				"Failed to get information for the file due to a file system error.");
		}

		auto lastModified = toRFC822DateTimeString(dirent.timeModified.toUTC());
		auto creationDate = toRFC822DateTimeString(dirent.timeCreated.toUTC());
		isCollection = pathstr.isDir;

		auto etag = "\"" ~ hexDigest!MD5(pathstr ~ ":" ~ lastModified ~ ":" ~ to!string(dirent.size)).idup ~ "\"";

		string resType = "";
		properties["d:getetag"] = etag[1..$-1];
		properties["d:getlastmodified"] = lastModified;
		properties["d:creationdate"] = creationDate;

		if(!isCollection) {
			properties["d:getcontentlength"] = dirent.size.to!string;
			properties["d:getcontenttype"] = getMimeTypeForFile(pathstr);
		}

		href = path.toString;

		statusCode = HTTPStatus.OK;
	}

	override DavResource[] getChildren(ulong depth = 1) {
		DavResource[] list;

		if(depth == 0) return list;
		string listPath = filePath.toString.decode;
		string rootPath = fileRoot.toString.decode;

		auto fileList = dirEntries( listPath, "*", SpanMode.shallow);

		foreach(file; fileList) {
			string fileName = baseName(file.name);

			URL childUrl = url;
			childUrl.path = childUrl.path ~ fileName;

	   		auto resource = new DavFileResource(dav, fileRoot, childUrl);

	   		list ~= resource;

	   		if(resource.isCollection && depth > 0)
	   			list ~= resource.getChildren(depth - 1);
		}

		return list;
	}

	override void remove() {
		if(isCollection) {
			auto childList = getChildren;

			foreach(c; childList)
				c.remove;

			filePath.toString.rmdir;
		} else {
			filePath.toString.remove;
		}
	}

	unittest {
		"level1/level2".mkdirRecurse;
		"level1/level2/testFile1.txt".write("hello!");
		"level1/level2/testFile2.txt".write("hello!");

		auto dav = new FileDav();
		dav.root = Path("");

		auto file = dav.getResource(Path("/level1"));
		file.remove;

		assert(!"level1".exists);
	}

	override void move(URL destinationUrl, bool overwrite = false) {
		Path urlPath = destinationUrl.pathString;
		Path destinationPath = fileRoot ~ urlPath.toString.decode[1..$];

		auto parentResource = dav.getResource(url.parentURL);

		if(destinationPath == filePath)
			throw new DavException(HTTPStatus.forbidden, "Destination same as source.");

		if(!overwrite && parentResource.hasChild(urlPath))
			throw new DavException(HTTPStatus.preconditionFailed, "Destination already exists.");

		copy(destinationUrl, overwrite);
		remove;
	}

	override void copy(URL destinationURL, bool overwrite = false) {
		string destinationPath = (fileRoot ~ destinationURL.path.toString[1..$]).toString.decode;

		writeln("COPY: ", destinationPath);

		if(!overwrite && destinationPath.exists)
			throw new DavException(HTTPStatus.preconditionFailed, "Destination already exists.");

		if(isCollection) {
			destinationPath.mkdirRecurse;

			auto childList = getChildren;
			foreach(c; childList) {
				URL childURL = destinationURL;
				childURL.path = destinationURL.path ~ c.name;
				c.copy(childURL);
			}
		} else {
			filePath.toString.copy(destinationPath);
		}
	}

	unittest {
		"testFile.txt".write("hello!");

		auto dav = new FileDav();
		dav.root = Path("");

		auto file = dav.getResource(Path("/testFile.txt"));
		file.copy(Path("/testCopy.txt"));

		assert("hello!" == "testCopy.txt".read);

		"testFile.txt".remove;
		"testCopy.txt".remove;
	}

	unittest {
		"level1/level2".mkdirRecurse;
		"level1/level2/testFile.txt".write("hello!");

		auto dav = new FileDav();
		dav.root = Path("");

		auto file = dav.getResource(Path("/level1"));
		file.copy(Path("/_test"));

		assert("hello!" == "_test/level2/testFile.txt".read);

		"level1".rmdirRecurse;
		"_test".rmdirRecurse;
	}


	override void setContent(const ubyte[] content) {
		immutable string p = filePath.to!string;
		p.write(content);
	}
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

		bool[string] propList(XmlNode document) {
			bool[string] list;

			XmlNode[] prop = document.parseXPath("d:propfind/d:prop");

			if(prop.length > 0) {
				auto properties = prop[0].getChildren;

				foreach(p; properties)
					list[p.getName.toLower] = true;
			}
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
			XmlNode document = readDocument(requestXml);
			properties = propList(document);
		}

		auto selectedResource = getResource(req.fullURL);

		auto response = new PropfindResponse();
		response.list = selectedResource ~ selectedResource.getChildren(depth);

		res.statusCode = HTTPStatus.multiStatus;

		if(properties.length == 0)
			res.writeBody(response.toString, "application/xml");
		else
			res.writeBody(response.toStringProps(properties), "application/xml");
	}

	void lock(HTTPServerRequest req, HTTPServerResponse res) {
		string path = getRequestPath(req);
		ulong depth = getDepth(req);
		string timeout = getHeader!"Timeout"(req.headers);

		bool[string] properties;

		string requestXml = cast(string)req.bodyReader.readAllUTF8;

		if(requestXml.length == 0)
			throw new DavException(HTTPStatus.internalServerError, "LOCK body expected.");

		XmlNode document = readDocument(requestXml);
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

		writeln("PUT ", path);
		writeln("PUT ", req.headers);

		DavResource resource = getOrCreateResource(req.fullURL, res.statusCode);

		writeln("resource ", resource);

		auto content = req.bodyReader.readAll;
		resource.setContent(content);

		res.writeBody("", "text/plain");
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
		auto selectedResource = getResource(req.fullURL);
		selectedResource.remove();

		res.writeBody("", "text/plain");
	}

	void move(HTTPServerRequest req, HTTPServerResponse res) {
		string path = getRequestPath(req);

		res.statusCode = HTTPStatus.noContent;
		auto selectedResource = getResource(req.fullURL);

		string destination = getHeader!"Destination"(req.headers);
		string overwrite = getHeader!"Overwrite"(req.headers);

		selectedResource.move(URL(destination));

		res.writeBody("", "text/plain");
	}
}

/// File dav impplementation
class FileDav : Dav {
	@property
	Path filePath(URL url) {
		return root ~ url.path.toString[1..$];
	}

	override DavResource getResource(URL url) {
		auto filePath = filePath(url);

		if(!filePath.toString.exists)
			throw new DavException(HTTPStatus.notFound, "`" ~ url.toString ~ "` not found.");

		return new DavFileResource(this, root, url);
	}

	override DavResource createCollection(URL url) {
		auto filePath = filePath(url);

		if(filePath.toString.exists)
			throw new DavException(HTTPStatus.methodNotAllowed, "plain/text");

		mkdir(filePath.toString);

		return new DavFileResource(this, root, url);
	}

	override DavResource createProperty(URL url) {
		auto filePath = filePath(url);

		if(filePath.toString.exists)
			throw new DavException(HTTPStatus.methodNotAllowed, "plain/text");

		filePath.toString.write("");

		return new DavFileResource(this, root, url);
	}
}

HTTPServerRequestDelegate serveDav(T : Dav)(Path path) {
	auto dav = new T;
	dav.root = path;

	void callback(HTTPServerRequest req, HTTPServerResponse res)
	{
		try {

			writeln("==> GOT: ", req.method, " ", req.path);

			if(req.method == HTTPMethod.OPTIONS) {
				dav.options(req, res);
			} else if(req.method == HTTPMethod.PROPFIND) {
				dav.propfind(req, res);
			} else if(req.method == HTTPMethod.GET) {
				dav.get(req, res);
			} else if(req.method == HTTPMethod.PUT) {
				dav.put(req, res);
			} else if(req.method == HTTPMethod.LOCK) {
				dav.lock(req, res);
			} else if(req.method == HTTPMethod.MKCOL) {
				dav.mkcol(req, res);
			} else if(req.method == HTTPMethod.DELETE) {
				dav.remove(req, res);
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

HTTPServerRequestDelegate serveFileDav(Path path) {
	return serveDav!FileDav(path);
}
