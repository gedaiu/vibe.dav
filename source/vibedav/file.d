/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 2 25, 2015
 * License: Subject to the	 terms of the MIT license, as written in the included LICENSE.txt file.
 * Copyright: Public Domain
 */
module vibedav.file;

public import vibedav.base;

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

import tested: testName = name;

/// File dav impplementation
class FileDav : Dav {
	@property
	Path filePath(URL url) {
		return root ~ url.path.toString[1..$];
	}

	override DavResource getResource(URL url) {
		auto filePath = filePath(url);

		writeln("=====filePath ", filePath);

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

		writeln("pathstr == ", pathstr );

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
		properties["d:getetag"] = new DavProp(etag[1..$-1]);
		properties["d:getlastmodified"] = new DavProp(lastModified);
		properties["d:creationdate"] = new DavProp(creationDate);

		if(!pathstr.isDir) {
			properties["d:getcontentlength"] = new DavProp(dirent.size.to!string);
			properties["d:getcontenttype"] = new DavProp(getMimeTypeForFile(pathstr));
		}

		href = path.toString;
	}

	@property
	override string eTag() {
		return getEtag(filePath);
	}

	override DavResource[] getChildren(ulong depth = 1) {
		DavResource[] list;

		if(depth == 0) return list;
		string listPath = filePath.toString.decode;
		string rootPath = fileRoot.toString.decode;

		auto fileList = dirEntries(listPath, "*", SpanMode.shallow);

		foreach(file; fileList) {
			string fileName = baseName(file.name);

			URL childUrl = url;
			childUrl.path = childUrl.path ~ fileName;

	   		auto resource = new DavFileResource(this.dav, fileRoot, childUrl);

	   		list ~= resource;

	   		if(resource.isCollection && depth > 0)
	   			list ~= resource.getChildren(depth - 1);
		}

		return list;
	}

	override void remove() {
		super.remove;

		if(isCollection) {
			auto childList = getChildren;

			foreach(c; childList)
				c.remove;

			filePath.toString.rmdir;
		} else
			filePath.toString.remove;
	}

	@testName("exists")
	unittest {
		"level1/level2".mkdirRecurse;
		"level1/level2/testFile1.txt".write("hello!");
		"level1/level2/testFile2.txt".write("hello!");

		auto dav = new FileDav;
		dav.root = Path("");

		auto file = dav.getResource(URL("http://127.0.0.1/level1"));
		file.remove;

		assert(!"level1".exists);
	}

	override HTTPStatus move(URL destinationUrl, bool overwrite = false) {
		Path urlPath = destinationUrl.pathString;
		Path destinationPath = fileRoot ~ urlPath.toString.decode[1..$];

		auto parentResource = dav.getResource(url.parentURL);

		if(destinationPath == filePath)
			throw new DavException(HTTPStatus.forbidden, "Destination same as source.");

		if(!overwrite && parentResource.hasChild(urlPath))
			throw new DavException(HTTPStatus.preconditionFailed, "Destination already exists.");

		auto retStatus = copy(destinationUrl, overwrite);
		remove;

		return retStatus;
	}

	override HTTPStatus copy(URL destinationURL, bool overwrite = false) {
		HTTPStatus retCode = HTTPStatus.created;

		auto destinationPathObj = (fileRoot ~ destinationURL.path.toString[1..$]);
		destinationPathObj.endsWithSlash = false;

		string destinationPath = destinationPathObj.toString.decode;
		string sourcePath = filePath.toString;

		if(!overwrite && destinationPath.exists)
			throw new DavException(HTTPStatus.preconditionFailed, "Destination already exists.");

		if(isCollection) {
			if(destinationPath.exists && !destinationPath.isDir) destinationPath.remove;

			destinationPath.mkdirRecurse;

			auto childList = getChildren;
			foreach(c; childList) {
				URL childURL = destinationURL;
				childURL.path = destinationURL.path ~ c.name;
				c.copy(childURL, overwrite);
			}
		} else {
			string parentPath = Path(destinationPath).parentPath.toString;
			if(parentPath != "" && !parentPath.exists)
				throw new DavException(HTTPStatus.conflict, "Conflict. `" ~ parentPath ~ "` does not exist.");

			if(destinationPath.exists && destinationPath.isDir != sourcePath.isDir) {
				auto destinationResource = dav.getResource(destinationURL);
				destinationResource.remove;
				retCode = HTTPStatus.noContent;
			}
			sourcePath.copy(destinationPath);
		}

		super.copy(destinationURL, overwrite);

		return retCode;
	}

	@testName("copy file")
	unittest {
		"testFile.txt".write("hello!");

		auto dav = new FileDav();
		dav.root = Path("");

		auto file = dav.getResource(URL("http://127.0.0.1/testFile.txt"));
		if("testCopy.txt".exists) "testCopy.txt".remove;
		file.copy(URL("http://127.0.0.1/testCopy.txt"), true);

		assert("hello!" == "testCopy.txt".read);

		"testFile.txt".remove;
		"testCopy.txt".remove;
	}

	@testName("copy dir")
	unittest {
		"level1/level2".mkdirRecurse;
		"level1/level2/testFile.txt".write("hello!");

		auto dav = new FileDav();
		dav.root = Path("");

		auto file = dav.getResource(URL("http://127.0.0.1/level1"));
		file.copy(URL("http://127.0.0.1/_test"));

		assert("hello!" == "_test/level2/testFile.txt".read);

		"level1".rmdirRecurse;
		"_test".rmdirRecurse;
	}

	override void setContent(const ubyte[] content) {
		immutable string p = filePath.to!string;
		p.write(content);
	}
}

HTTPServerRequestDelegate serveFileDav(Path path) {
	return serveDav!FileDav(path);
}
