/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 2 25, 2015
 * License: Subject to the	 terms of the MIT license, as written in the included LICENSE.txt file.
 * Copyright: Public Domain
 */
module vibedav.filedav;

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

/// File dav impplementation
class FileDav : Dav {
	protected {
		Path rootFile;
	}

	this() {
		this("","");
	}

	this(string rootUrl, string rootFile) {
		super(rootUrl);
		this.rootFile = Path(rootFile);
	}

	Path filePath(URL url) {
		return rootFile ~ url.path.toString[rootUrl.toString.length..$];
	}

	override DavResource getResource(URL url) {
		auto filePath = filePath(url);

		if(!filePath.toString.exists)
			throw new DavException(HTTPStatus.notFound, "`" ~ url.toString ~ "` not found.");

		return new DavFileResource(this, url);
	}

	override DavResource createCollection(URL url) {
		auto filePath = filePath(url);

		if(filePath.toString.exists)
			throw new DavException(HTTPStatus.methodNotAllowed, "plain/text");

		mkdir(filePath.toString);

		return new DavFileResource(this, url);
	}

	override DavResource createProperty(URL url) {
		auto filePath = filePath(url);

		if(filePath.toString.exists)
			throw new DavException(HTTPStatus.methodNotAllowed, "plain/text");

		auto f = new File(filePath.toString, "w");
		f.close;

		return new DavFileResource(this, url);
	}
}

/// Represents a file or directory DAV resource
class DavFileResource : DavResource {

	private immutable {
		Path resPath;
		Path filePath;
	}

	protected {
		FileDav dav;
	}

	this(FileDav dav, URL url) {
		super(dav, url);

		this.dav = dav;
		auto path = url.path;

		path.normalize;

		logTrace("create DAV file resource %s %s", dav.rootFile , path);

		resPath = path;
		filePath = dav.filePath(url);

		auto pathstr = filePath.toNativeString();

		if(!pathstr.exists)
			throw new DavException(HTTPStatus.notFound, "File not found.");

		FileInfo dirent = getFileInfo(pathstr);

		auto creationDate = toRFC822DateTimeString(dirent.timeCreated.toUTC());
		isCollection = pathstr.isDir;

		string resType = "";
		properties["d:creationdate"] = new DavProp(creationDate);

		if(!pathstr.isDir) {
			properties["d:getcontenttype"] = new DavProp(getMimeTypeForFile(pathstr));
		}

		href = path.toString;
	}

	@property override {
		string eTag() {
			import std.digest.crc;
			import std.stdio;

			auto pathstr = filePath.toNativeString();
			string fileHash = pathstr;

			if(!pathstr.isDir) {
				auto f = File(pathstr, "r");
				foreach (ubyte[] buffer; f.byChunk(4096)) {
					ubyte[4] hash = crc32Of(buffer);
					fileHash ~= crcHexString(hash);
			    }
			}

			fileHash ~= lastModified.toISOExtString ~ contentLength.to!string;

			auto etag = hexDigest!MD5(pathstr ~ fileHash);
			return etag.to!string;
		}

		string mimeType() {
			return getMimeTypeForFile(filePath.toString);
		}

		SysTime lastModified() {
			FileInfo dirent = getFileInfo(filePath.toNativeString);
			return dirent.timeModified.toUTC;
		}

		ulong contentLength() {
			FileInfo dirent = getFileInfo(filePath.toNativeString);
			return dirent.size;
		}

		InputStream stream() {
			FileStream fil;
			fil = openFile(filePath.toString);

			return fil;
		}
	}

	override DavResource[] getChildren(ulong depth = 1) {
		DavResource[] list;

		if(depth == 0) return list;
		string listPath = filePath.toString.decode;
		string rootPath = dav.rootFile.toString.decode;

		auto fileList = dirEntries(listPath, "*", SpanMode.shallow);

		foreach(file; fileList) {
			string fileName = baseName(file.name);

			URL childUrl = url;
			childUrl.path = childUrl.path ~ fileName;

	   		auto resource = new DavFileResource(this.dav, childUrl);

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
		std.file.write("level1/level2/testFile1.txt", "hello!");
		std.file.write("level1/level2/testFile2.txt", "hello!");

		auto dav = new FileDav;

		auto file = dav.getResource(URL("http://127.0.0.1/level1"));
		file.remove;

		assert(!"level1".exists);
	}

	override HTTPStatus move(URL destinationUrl, bool overwrite = false) {
		Path destinationPath = dav.filePath(destinationUrl);

		auto parentResource = dav.getResource(url.parentURL);

		if(destinationPath == filePath)
			throw new DavException(HTTPStatus.forbidden, "Destination same as source.");

		if(!overwrite && parentResource.hasChild(destinationUrl.path))
			throw new DavException(HTTPStatus.preconditionFailed, "Destination already exists.");

		auto retStatus = copy(destinationUrl, overwrite);
		remove;

		return retStatus;
	}

	override HTTPStatus copy(URL destinationURL, bool overwrite = false) {
		HTTPStatus retCode = HTTPStatus.created;

		auto destinationPathObj = dav.filePath(destinationURL);
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
		std.file.write("testFile.txt", "hello!");

		auto dav = new FileDav;

		auto file = dav.getResource(URL("http://127.0.0.1/testFile.txt"));
		if("testCopy.txt".exists) std.file.remove("testCopy.txt");
		file.copy(URL("http://127.0.0.1/testCopy.txt"), true);

		assert("hello!" == "testCopy.txt".read);

		std.file.remove("testFile.txt");
		std.file.remove("testCopy.txt");
	}

	@testName("copy dir")
	unittest {
		"level1/level2".mkdirRecurse;
		std.file.write("level1/level2/testFile.txt", "hello!");

		auto dav = new FileDav;

		auto file = dav.getResource(URL("http://127.0.0.1/level1"));
		file.copy(URL("http://127.0.0.1/_test"));

		assert("hello!" == read("_test/level2/testFile.txt"));

		"level1".rmdirRecurse;
		"_test".rmdirRecurse;
	}

	override {
		void setContent(const ubyte[] content) {
			immutable string p = filePath.to!string;
			std.stdio.write(p, content);
		}

		void setContent(InputStream content, ulong size) {
			auto strPath = filePath.to!string;
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
			std.file.copy(tmpPath, strPath);
			std.file.remove(tmpPath);
		}
	}
}

void serveFileDav(URLRouter router, string rootUrl, string rootPath) {
	FileDav fileDav = new FileDav(rootUrl, rootPath);
	router.any(rootUrl ~ "*", serveDav(fileDav));
}
