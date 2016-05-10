/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 3 10, 2015
 * License: Subject to the	 terms of the MIT license, as written in the included LICENSE.txt file.
 * Copyright: Public Domain
 */
module vibedav.locks;

import vibedav.prop;
import vibedav.ifheader;

import std.datetime;
import std.uuid;
import std.string;

import vibe.core.log;
import vibe.core.file;
import vibe.inet.mimetypes;
import vibe.inet.message;
import vibe.http.server;
import vibe.http.fileserver;
import vibe.http.router : URLRouter;
import vibe.stream.operations;
import vibe.utils.dictionarylist;

//412 (Precondition Failed)

class DavLockInfo {

	enum Scope {
		exclusiveLock,
		sharedLock
	};

	private SysTime _timeout;

	string rootURL;

	Scope scopeLock;
	bool isWrite;
	string owner;
	string uuid;
	DavDepth depth;

	this() {
		auto id = randomUUID();
		uuid = "urn:uuid:" ~ id.toString();
	}

	this(string uuid) {
		this.uuid = uuid;
	}

	static DavLockInfo fromXML(DavProp node) {
		auto lock = new DavLockInfo;

		if("lockinfo" !in node || "lockscope" !in node["lockinfo"])
			throw new DavException(HTTPStatus.preconditionFailed, "Lockinfo is missing.");

		if("shared" in node["lockinfo"]["lockscope"])
			lock.scopeLock = Scope.sharedLock;

		if("locktype" in node["lockinfo"] && "write" in node["lockinfo"]["locktype"])
			lock.isWrite = true;

		lock.owner = node["lockinfo"]["owner"].value;

		return lock;
	}

	static DavLockInfo fromXML(DavProp node, DavResource resource) {
		auto lock = DavLockInfo.fromXML(node);
		lock.rootURL = resource.fullURL;

		return lock;
	}

	@property {
		/// Set the timeout based on the request header
		void timeout(Duration val) {
			_timeout = Clock.currTime + val;
		}
	}

	override string toString() {
		import std.conv : to;
		
		string a = `<d:activelock>`;

		if(isWrite)
			a ~= `<d:locktype><d:write/></d:locktype>`;

		if(scopeLock == Scope.exclusiveLock)
			a ~= `<d:lockscope><d:exclusive/></d:lockscope>`;
		else if(scopeLock == Scope.sharedLock)
			a ~= `<d:lockscope><d:shared/></d:lockscope>`;

		if(depth == DavDepth.zero)
			a ~= `<d:depth>0</d:depth>`;
		else if(depth == DavDepth.infinity)
			a ~= `<d:depth>infinity</d:depth>`;

		if(owner != "")
			a ~= `<d:owner><d:href>`~owner~`</d:href></d:owner>`;

		if(_timeout == SysTime.max)
			a ~= `<d:timeout>Infinite</d:timeout>`;
		else {
			long seconds = (_timeout - Clock.currTime).total!"seconds";
			a ~= `<d:timeout>Second-` ~ seconds.to!string ~ `</d:timeout>`;
		}

		a ~= `<d:locktoken><d:href>`~uuid~`</d:href></d:locktoken>`;
		a ~= `<d:lockroot><d:href>`~URL(rootURL).path.toNativeString~`</d:href></d:lockroot>`;
		a ~= `</d:activelock>`;

		return a;
	}
}

class DavLockList {
	protected {
		DavLockInfo[string][string] locks;
		string[string] etags;
	}

	bool hasEtag(string url, string etag) {
		return url in etags && etags[url] == etag;
	}

	bool existLock(string url, string uuid) {
		bool result;
		if(url !in locks || uuid !in locks[url])
			result = false;
		else
			result = true;

		if(url == "DAV:no-lock")
			return !result;

		return result;
	}

	bool checkCondition(URL url, IfHeader header) {
		bool partialResult;
		string strUrl = url.toString;

		if(header.isEmpty)
			return true;

		//check the if header
		foreach(string conditionUrl, ifConditionList; header.list) {
			if(conditionUrl == "") conditionUrl = strUrl;

			foreach(ifCondition; ifConditionList) {
				bool conditionResult;

				//check for conditions
				bool result = existLock(conditionUrl, ifCondition.condition);
				if(ifCondition.isNot)
					result = !result;

				if(result) {
					//check for etag
					if(ifCondition.etag != "")
						conditionResult = hasEtag(conditionUrl, ifCondition.etag);
					else
						conditionResult = true;
				}

				//compute the partial result
				partialResult = partialResult || conditionResult;
			}
		}

		return partialResult;
	}

	bool canResolve(string[] list, bool[string] headerLocks) {

		foreach(i; 0..list.length)
			if(list[i] !in headerLocks)
				return false;

		return true;
	}

	bool check(URL url, IfHeader header = IfHeader()) {
		if(!checkCondition(url, header))
			throw new DavException(HTTPStatus.preconditionFailed, "Precondition failes.");

		auto mustResolve = lockedParentResource(url);

		if(!canResolve(mustResolve, header.getLocks(url.toString)))
			throw new DavException(HTTPStatus.locked, "Locked.");

		return true;
	}

	string[] lockedParentResource(URL url, long depth = -1) {
		string[] list;
		string path = url.path.toString;
		string strUrl = url.toString;

		if(strUrl in locks)
			foreach(uuid, lock; locks[strUrl])
				if(depth <= lock.depth)
					list ~= uuid;

		if(path == "/")
			return list;
		else
			return list ~ lockedParentResource(url.parentURL, depth + 1);
	}

	void add(DavLockInfo lockInfo) {
		locks[lockInfo.rootURL][lockInfo.uuid] = lockInfo;
	}

	void remove(DavResource resource, string token) {
		string strUrl = resource.fullURL;
		ulong index;

		if(strUrl !in locks)
			throw new DavException(HTTPStatus.conflict ,"The resource is already unlocked.");

		if(token !in locks[strUrl])
			throw new DavException(HTTPStatus.conflict ,"Invalid lock uuid.");

		locks[resource.fullURL].remove(token);

		if(locks[resource.fullURL].keys.length == 0)
			locks.remove(resource.fullURL);
	}

	bool hasLock(string url) {
		if(url !in locks)
			return false;

		if(locks[url].keys.length > 0)
			return false;

		return true;
	}

	bool hasExclusiveLock(string url) {
		if(url !in locks)
			return false;

		foreach(string uuid, lock; locks[url])
			if(lock.scopeLock == DavLockInfo.Scope.exclusiveLock)
				return true;

		return false;
	}

	DavLockInfo opIndex(string path, string uuid) {
		if(path !in locks || uuid !in locks[path])
			return null;

		return locks[path][uuid];
	}

	DavLockInfo[string] opIndex(string path) {
		if(path !in locks)
			return null;

		return locks[path];
	}

	void setETag(URL url, string etag) {
		etags[url.toString] = etag;
	}
}
