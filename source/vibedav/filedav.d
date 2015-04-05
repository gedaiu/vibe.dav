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

string stripSlashes(string path) {
	if(path.length > 0 && path[0] == '/')
		path = path[1..$];

	if(path.length > 1 && path[0..2] == "./")
		path = path[2..$];

	if(path.length > 0 && path[path.length-1] == '/')
		path = path[0..$-1];

	return path;
}

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

bool[string] getFolderContent(string format = "*")(string path, Path rootPath, Path rootUrl) {
	bool[string] list;
	rootPath.endsWithSlash = true;
	string strRootPath = rootPath.toString;

	auto p = Path(path);
	p.endsWithSlash = true;
	path = p.toString;

	enforce(path.isDir);
	enforce(strRootPath.length <= path.length);
	enforce(strRootPath == path[0..strRootPath.length]);

	auto fileList = dirEntries(path, format, SpanMode.shallow);

	foreach(file; fileList) {
		auto filePath = rootUrl ~ file[strRootPath.length..$];
		filePath.endsWithSlash = false;

		if(file.isDir)
			list[filePath.toString] = true;
		else
			list[filePath.toString] = false;
	}

	return list;
}

interface IFileDav : IDav {
	Path filePath(URL url);
	Path rootFile();
	void match(string path, T)();
}

abstract class FileDavResourceBase : DavResource {

	protected {
		immutable Path filePath;
		immutable string nativePath;
		IFileDav dav;
	}

	this(IFileDav dav, URL url, bool forceCreate = false) {
		super(dav, url);

		this.dav = dav;
		auto path = url.path;

		path.normalize;

		filePath = dav.filePath(url);
		nativePath = filePath.toNativeString();

		if(!forceCreate && !nativePath.exists)
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

		string[] resourceType() {
			return ["collection:DAV:"];
		}

		override bool isCollection() {
			return nativePath.isDir;
		}

		Path rootPath() {
			return dav.rootFile;
		}

		Path rootUrl() {
			return dav.rootUrl;
		}

		override {
			InputStream stream() {
				return nativePath.toStream;
			}

			pure nothrow string type() {
				return "FileDavResourceBase";
			}
		}
	}
}

/// Represents a Folder DAV resource
class FileDavCollection : FileDavResourceBase {

	this(IFileDav dav, URL url, bool forceCreate = false) {
		super(dav, url, forceCreate);

		if(nativePath.exists && !nativePath.isDir)
			throw new DavException(HTTPStatus.internalServerError, nativePath ~ ": Path must be a folder.");

		if(forceCreate && !nativePath.exists)
			nativePath.mkdirRecurse;
	}

	override bool[string] getChildren() {
		return getFolderContent!"*"(nativePath, dav.rootFile, dav.rootUrl);
	}

	override void remove() {
		super.remove;

		foreach(string path, bool isCollection; getChildren)
			dav.getResource(URL("http://a/" ~ path)).remove;

		nativePath.rmdir;
	}

	@testName("Remove")
	unittest {
		"test/level1/level2".mkdirRecurse;

		alias factory = FileDavResourceFactory!(
			"","test",
			"", FileDavCollection, FileDavResource);

		auto dav = new FileDav!factory;
		auto file = dav.getResource(URL("http://127.0.0.1/level1/"));
		file.remove;

		assert(!"./test/level1".exists);

		"test".rmdirRecurse;
	}

	override {
		void setContent(const ubyte[] content) {
			throw new DavException(HTTPStatus.conflict, "Can't set folder content.");
		}

		void setContent(InputStream content, ulong size) {
			throw new DavException(HTTPStatus.conflict, "Can't set folder content.");
		}
	}

	pure @property {
		string contentType() {
			// https://tools.ietf.org/html/rfc2425
			return "text/directory";
		}

		ulong contentLength() {
			return 0;
		}

		override nothrow string type() {
			return "FileDavCollection";
		}
	}
}

/// Represents a file DAV resource
class FileDavResource : FileDavResourceBase {

	this(IFileDav dav, URL url, bool forceCreate = false) {
		super(dav, url, forceCreate);

		if(nativePath.exists && nativePath.isDir)
			throw new DavException(HTTPStatus.internalServerError, nativePath ~ ": Path must be a file.");

		if(forceCreate && !nativePath.exists)
			File(nativePath, "w");
	}

	override bool[string] getChildren() {
		return getFolderContent!"*"(nativePath, dav.rootFile, dav.rootUrl);
	}

	override void remove() {
		super.remove;
		nativePath.remove;
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

	@property {
		ulong contentLength() {
			return nativePath.contentLength;
		}

		string contentType() {
			return getMimeTypeForFile(nativePath);
		}

		override nothrow string type() {
			return "FileDavResource";
		}
	}
}

/**
	Initialisation

	FileDavResourceFactory!(
		RootUrl, RootFile,
		"/", FileDavCollection, FileDavResource,
		...
	)
*/
class FileDavResourceFactory(T...) if(T.length >= 5) {

	enum RootUrl = T[0].stripSlashes;
	enum RootFile = T[1].stripSlashes;

	static {
		Path FilePath(URL url) {
			string path = url.path.toString.stripSlashes;
			string filePath;

			filePath = path[RootUrl.length..$].stripSlashes;

			return Path(RootFile) ~ filePath;
		}

		DavResource CreateCollection(IFileDav dav, URL url) {
			auto filePath = FilePath(url);

			if(filePath.toString.exists)
				throw new DavException(HTTPStatus.methodNotAllowed, "Colection already exists.");

			auto pos = ResourceTypeIndex(url);

			return CreateResourceWithDavType!(T[3..$])(dav, pos, url);
		}

		DavResource CreateResource(IFileDav dav, URL url) {
			auto filePath = FilePath(url);

			if(filePath.toString.exists)
				throw new DavException(HTTPStatus.methodNotAllowed, "Resource already exists.");

			auto pos = ResourceTypeIndex(url);

			return CreateResourceWithDavType!(T[4..$])(dav, pos, url);
		}

		DavResource Get(IFileDav dav, const URL url) {
			DavResource res;
			Path path = FilePath(url);
			res = GetResourceOrCollection!(T[2..$])(dav, url, path);

			if(res is null)
				throw new DavException(HTTPStatus.notFound, "Not found");

			return res;
		}

		DavResource GetResourceOrCollection(List...)(IFileDav dav, const URL url, const Path path) {
			alias Resource = List[2];
			alias Collection = List[1];

			auto pos = ResourceTypeIndex(url);

			if(path.toNativeString.isDir)
				return NewResource!(List[1..$])(dav, pos, url);
			else
				return NewResource!(List[2..$])(dav, pos, url);
		}

		private {
			long ResourceTypeIndex(URL url) {
				Path path = FilePath(url);
				string strPath = path.toString;

				long pos = FindPathIndex!(T[2..$])(strPath);

				if(pos == -1)
					throw new DavException(HTTPStatus.notFound, "Not found");

				return pos;
			}

			DavResource NewResource(List...)(IFileDav dav, const long pos, const URL url) {
				alias Res = List[0];
				assert(pos < List.length);

				if(pos == 0)
					return new Res(dav, url);
				else static if(List.length >= 3)
					return NewResource!(List[3..$])(dav, pos - 1, url);
				else
					return null;
			}

			DavResource CreateResourceWithDavType (List...)(IFileDav dav, const long pos, const URL url) {
				alias Res = List[0];
				assert(pos < List.length);

				if(pos == 0)
					return new Res(dav, url, true);
				else static if(List.length >= 3)
					return CreateResourceWithDavType!(List[3..$])(dav, pos - 1, url);
				else
					return null;
			}

			long FindPathIndex(List...)(const string path, const ulong score = 0, const ulong start = 0) {

				if(path == List[0])
					return start;

				bool found;

				if(List[0].length >= score && path.length >= List[0].length && path[0..List[0].length] == List[0])
					found = true;

				static if(List.length > 3) {
					long otherRes;

					if(found)
						otherRes = FindPathIndex!(List[3..$])(path, List[0].length, start+3);
					else
						otherRes = FindPathIndex!(List[3..$])(path, score, start+3);

					if(otherRes > -1)
						return otherRes;
				}

				return start;
			}
		}
	}
}

@testName("File path url without slashes")
unittest {
	alias T = FileDavResourceFactory!(
		"location", "test",
		"test", FileDavCollection, FileDavResource);

	auto dav = new FileDav!T;
	auto path = T.FilePath(URL("http://127.0.0.1/location/file.txt"));

	assert(path.toString == "test/file.txt");
}

@testName("File path url with slashes")
unittest {
	alias T = FileDavResourceFactory!(
		"/location/", "test",
		"test", FileDavCollection, FileDavResource);

	auto dav = new FileDav!T;
	auto path = T.FilePath(URL("http://127.0.0.1/location/file.txt"));

	assert(path.toString == "test/file.txt");
}

@testName("Factory get collection")
unittest {
	"./test/".mkdirRecurse;

	alias T = FileDavResourceFactory!(
		"", "test",
		"test", FileDavCollection, FileDavResource);

	auto dav = new FileDav!T;
	auto res = T.Get(dav, URL("http://127.0.0.1/"));

	assert(res.type == "FileDavCollection");
}

@testName("Factory create collection")
unittest {
	"test/".mkdirRecurse;

	alias T = FileDavResourceFactory!(
		"", "test",
		"test", FileDavCollection, FileDavResource);

	auto dav = new FileDav!T;
	auto res = T.CreateCollection(dav, URL("http://127.0.0.1/newCollection"));

	assert("test/newCollection".exists);
	assert("test/newCollection".isDir);
	assert(res.type == "FileDavCollection");

	"test".rmdirRecurse;
}


@testName("Factory create resource")
unittest {
	"./test/".mkdirRecurse;

	alias T = FileDavResourceFactory!(
		"", "test",
		"test", FileDavCollection, FileDavResource);

	auto dav = new FileDav!T;
	auto res = T.CreateResource(dav, URL("http://127.0.0.1/newResource.txt"));

	assert("test/newResource.txt".exists);
	assert(!"test/newResource.txt".isDir);
	assert(res.type == "FileDavResource");

	"test".rmdirRecurse;
}

template FileDav(alias T) {
	alias FileDav = FileDav!(typeof(T));
}

/// File Dav impplementation
class FileDav(T) : DavBase, IFileDav {

	this() {
		super(T.RootUrl);
	}

	Path filePath(URL url) {
		return T.FilePath(url);
	}

	DavResource getResource(URL url) {
		auto filePath = filePath(url);

		if(!filePath.toString.exists)
			throw new DavException(HTTPStatus.notFound, "`" ~ url.toString ~ "` not found.");

		return T.Get(this, url);
	}

	DavResource[] getResources(URL url, ulong depth, IDavUser user) {
		DavResource[] list;
		auto filePath = filePath(url);

		if(!filePath.toString.exists)
			throw new DavException(HTTPStatus.notFound, "`" ~ url.toString ~ "` not found.");

		auto res = getResource(url);

		if(res !is null) {
			list ~= res;

			if(res.isCollection && depth > 0) {
				auto childList = res.getChildren;

				foreach(string path, bool isDir; childList) {
					list ~= getResources(URL("http://a/" ~ path), depth - 1, user);
				}
			}
		}

		return list;
	}

	DavResource createCollection(URL url) {
		return T.CreateCollection(this, url);
	}

	DavResource createResource(URL url) {
		return T.CreateResource(this, url);
	}

	DavResource createResources(URL url, ulong depth) {
		auto filePath = filePath(url);
		auto strFilePath = filePath.toString;

		if(strFilePath.exists)
			throw new DavException(HTTPStatus.methodNotAllowed, "Resource already exists.");

		if(filePath.endsWithSlash) {
			strFilePath.mkdirRecurse;
		} else {
			auto f = new File(strFilePath, "w");
			f.close;
		}

		return T.CreateResource(this, url);
	}

	@property Path rootFile() {
		return Path(T.RootFile);
	}
}

void serveFileDav(string rootUrl, string rootPath)(URLRouter router, IDavUserCollection userCollection) {

	alias T = FileDavResourceFactory!(
		rootUrl, rootPath,
		"", FileDavCollection, FileDavResource
	);

	router.serveFileDav!T(userCollection);
}

@testName("FileDav copy folder")
unittest {
	/// create the webdav instance
	alias T = FileDavResourceFactory!(
		"test/", "test",
		"", FileDavCollection, FileDavResource
	);

	auto fileDav = new FileDav!T;

	/// create some items
	"test/src/folder".mkdirRecurse;
	new File("test/src/file.txt", "w");

	/// do the copy
	string[string] headers = ["Depth": "infinity", "Destination":"http://127.0.0.1/test/dest/", "Overwrite": "F", "X-Forwarded-Host": "a"];
	DavRequest request = DavRequest.Create("/test/src/", headers);
	DavResponse response = DavResponse.Create;
	fileDav.copy(request, response);

	/// check
	assert("test/dest".exists, "dest not found");
	assert("test/dest/folder".exists, "folder not found");
	assert("test/dest/file.txt".exists, "file.txt not found");

	"test".rmdirRecurse;
}

@testName("FileDav check if propfind fails")
unittest {
	/// create the webdav instance
	alias T = FileDavResourceFactory!(
		"test/", "test",
		"", FileDavCollection, FileDavResource
	);

	auto fileDav = new FileDav!T;

	/// create some items
	"test".mkdir;
	new File("test/prop", "w");

	/// do the propfind
	string[string] headers = ["Depth": "0", "X-Forwarded-Host": "a"];
	DavRequest request = DavRequest.Create("/test/prop", headers);
	DavResponse response = DavResponse.Create;
	fileDav.propfind(request, response);

	/// check
	"test".rmdirRecurse;
}

void serveFileDav(T)(URLRouter router, IDavUserCollection userCollection) {
	auto fileDav = new FileDav!T;

	fileDav.userCollection = userCollection;
	router.any("/" ~ T.RootUrl ~ "/*", serveDav(fileDav));
}
