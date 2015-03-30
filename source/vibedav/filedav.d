/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 2 25, 2015
 * License: Subject to the	 terms of the MIT license, as written in the included LICENSE.txt file.
 * Copyright: Public Domain
 */
module vibedav.filedav;

import vibedav.base;

import vibe.core.log;
import vibe.core.file;
import vibe.inet.mimetypes;
import vibe.inet.message;
import vibe.http.server;
import vibe.http.fileserver;
import vibe.http.router : URLRouter;
import vibe.stream.operations;
import vibe.utils.dictionarylist;
import vibe.stream.stdio;
import vibe.stream.memory;
import vibe.utils.memory;

import std.conv : to;
import std.file;
import std.path;
import std.digest.md;
import std.datetime;
import std.string;
import std.stdio;
import std.typecons;
import std.uri;
import std.uuid;

import tested: testName = name;

/// Compute a file etag
string eTag(string path) {
	import std.digest.crc;
	import std.stdio;

	string fileHash = path;

	if(!path.isDir) {
		auto f = File(path, "r");
		foreach (ubyte[] buffer; f.byChunk(4096)) {
			ubyte[4] hash = crc32Of(buffer);
			fileHash ~= crcHexString(hash);
	    }
	}

	fileHash ~= path.lastModified.toISOExtString ~ path.contentLength.to!string;

	auto etag = hexDigest!MD5(path ~ fileHash);
	return etag.to!string;
}

SysTime lastModified(string path) {
	FileInfo dirent = getFileInfo(path);
	return dirent.timeModified.toUTC;
}

SysTime creationDate(string path) {
	FileInfo dirent = getFileInfo(path);
	return dirent.timeCreated.toUTC;
}

ulong contentLength(string path) {
	FileInfo dirent = getFileInfo(path);
	return dirent.size;
}

FileStream toStream(string path) {
	return openFile(path);
}

DavResource[] getFolderContent(TResource, TCollection, string format = "*")(string path, URL url, DavFs!(TResource, TCollection) dav, ulong depth = 1) {
	DavResource[] list;

	if(depth == 0) return list;

	auto fileList = dirEntries(path, format, SpanMode.shallow);

	foreach(file; fileList) {
		writeln("=> ", file);
		string fileName = baseName(file.name);

		URL childUrl = url;
		childUrl.path = childUrl.path ~ fileName;

		DavResource resource;

		if(file.isDir) {
			writeln("collection");
			resource = new TCollection(dav, childUrl);

			if(depth > 0)
				list ~= resource.getChildren(depth - 1);
		}
		else {
			writeln("resource");
			resource = new TResource(dav, childUrl);
		}

		list ~= resource;
	}

	return list;
}


abstract class DavFileBase(DavFsType) : DavResource {

	protected {
		immutable Path filePath;
		immutable string nativePath;
		DavFsType dav;
	}

	this(DavFsType dav, URL url) {
		super(dav, url);

		this.dav = dav;
		auto path = url.path;

		path.normalize;

		filePath = dav.filePath(url);
		nativePath = filePath.toNativeString();

		if(!nativePath.exists)
			throw new DavException(HTTPStatus.notFound, "File not found.");

		href = path.toString;
	}

	@property {
		string eTag() {
			return nativePath.eTag;
		}

		SysTime creationDate() {
			return nativePath.creationDate;
		}

		SysTime lastModified() {
			return nativePath.lastModified;
		}

		ulong contentLength() {
			return nativePath.contentLength;
		}

		string[] resourceType() {
			return ["collection:DAV:"];
		}

		override bool isCollection() {
			return nativePath.isDir;
		}

		override InputStream stream() {
			return nativePath.toStream;
		}
	}
}

alias DavFsFileType = DavFs!(DavFileResource, DavFileCollection);

/// Represents a Folder DAV resource
class DavFileCollection : DavFileBase!DavFsFileType {

	this(DavFsFileType dav, URL url) {
		super(dav, url);

		if(!nativePath.isDir)
			throw new DavException(HTTPStatus.internalServerError, nativePath ~ ": Path must be a folder.");
	}

	override DavResource[] getChildren(ulong depth = 1) {
		return getFolderContent(nativePath, url, dav, depth);
	}

	override void remove() {
		super.remove;

		foreach(c; getChildren)
			c.remove;

		nativePath.rmdir;
	}

	void setContent(const ubyte[] content) {
		throw new DavException(HTTPStatus.conflict, "Can't set folder content.");
	}

	void setContent(InputStream content, ulong size) {
		throw new DavException(HTTPStatus.conflict, "Can't set folder content.");
	}


	string contentType() {
		// https://tools.ietf.org/html/rfc2425
		return "text/directory";
	}
}

/// Represents a file DAV resource
class DavFileResource : DavFileBase!DavFsFileType {

	this(DavFsFileType dav, URL url) {
		super(dav, url);

		if(nativePath.isDir)
			throw new DavException(HTTPStatus.internalServerError, nativePath ~ ": Path must be a file.");
	}

	override DavResource[] getChildren(ulong depth = 0) {
		return getFolderContent(nativePath, url, dav, depth);
	}

	override void remove() {
		super.remove;
		nativePath.remove;
	}

	@testName("exists")
	unittest {
		"level1/level2".mkdirRecurse;

		auto dav = new DavFs!DavFileResource( "/", "./" );
		auto file = dav.getResource(URL("http://127.0.0.1/level1/"));
		file.remove;

		assert(!"level1".exists);
	}

	override {
		void setContent(const ubyte[] content) {
			std.stdio.write(nativePath, content);
		}

		void setContent(InputStream content, ulong size) {
			auto tmpPath = filePath.to!string ~ ".tmp";
			auto tmpFile = File(tmpPath, "w");

			while(!content.empty) {
				auto leastSize = content.leastSize;
				ubyte[] buf;
				buf.length = leastSize;
				content.read(buf);
				tmpFile.rawWrite(buf);
			}

			tmpFile.flush;
			std.file.copy(tmpPath, nativePath);
			std.file.remove(tmpPath);
		}
	}

	string contentType() {
		return getMimeTypeForFile(nativePath);
	}
}


/// File dav impplementation
class DavFs(TResource, TCollection) : Dav {
	protected {
		Path _rootFile;
	}

	this() {
		this("","");
	}

	this(string rootUrl, string _rootFile) {
		super(rootUrl);
		this._rootFile = Path(_rootFile);
	}

	Path filePath(URL url) {
		return _rootFile ~ url.path.toString[rootUrl.toString.length..$];
	}

	DavResource getResource(URL url) {
		auto filePath = filePath(url);

		if(!filePath.toString.exists)
			throw new DavException(HTTPStatus.notFound, "`" ~ url.toString ~ "` not found.");


		writeln(filePath.toString, "= ", filePath.toString.isDir);

		if(filePath.toString.isDir) {
			writeln("colection");
			return new TCollection(this, url);
		}
		else {
			writeln("resource");
			return new TResource(this, url);
		}
	}

	DavResource createCollection(URL url) {
		auto filePath = filePath(url);

		if(filePath.toString.exists)
			throw new DavException(HTTPStatus.methodNotAllowed, "Colection already exists.");

		mkdir(filePath.toString);
		return new TCollection(this, url);
	}

	DavResource createProperty(URL url) {
		auto filePath = filePath(url);
		auto strFilePath = filePath.toString;

		if(strFilePath.exists)
			throw new DavException(HTTPStatus.methodNotAllowed, "Property already exists.");

		if(filePath.endsWithSlash) {
			strFilePath.mkdirRecurse;
		} else {
			auto f = new File(strFilePath, "w");
			f.close;
		}

		return new TResource(this, url);
	}

	@property
	Path rootFile() {
		return _rootFile;
	}
}

void serveDavFs(T, U)(URLRouter router, string rootUrl, string rootPath, IDavUserCollection userCollection) {
	auto fileDav = new DavFs!(T, U)(rootUrl, rootPath);
	fileDav.userCollection = userCollection;
	router.any(rootUrl ~ "*", serveDav(fileDav));
}
