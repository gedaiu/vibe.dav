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

	string rootURL;

	Scope scopeLock;
	bool isWrite;
	string owner;
	SysTime timeout;
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

		a ~= `<D:locktoken><D:href>`~uuid~`</D:href></D:locktoken>`;
		a ~= `<D:lockroot><D:href>`~rootURL~`</D:href></D:lockroot>`;

		a ~= `</D:activelock></D:lockdiscovery></D:prop>`;

		return a;
	}
}

class DavLockList {
	protected {
		DavLockInfo[string][string] locks;
		string[string] etags;
	}

	bool hasEtag(string url, string etag) {
		writeln("hasEtag ", url in etags ,"&&", etags[url].to!string ,"==", etag.to!string);
		return url in etags && etags[url] == etag;
	}

	bool existLock(string url, string uuid) {
		bool result;
		writeln("LOCKS:", locks);
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

		writeln(header);

		if(header.isEmpty)
			return true;

		//check the if header
		foreach(string conditionUrl, ifConditionList; header.list) {
			if(conditionUrl == "") conditionUrl = strUrl;

			foreach(ifCondition; ifConditionList) {
				bool conditionResult;

				writeln("0.conditionResult:", conditionResult);
				writeln("existLock ", conditionUrl, " ", ifCondition);

				//check for conditions
				bool result = existLock(conditionUrl, ifCondition.condition);
				if(ifCondition.isNot)
					result = !result;

				if(result) {
					writeln("EXIST");
					writeln("1.conditionResult:", conditionResult);
					//check for etag
					if(ifCondition.etag != "") {
						conditionResult = hasEtag(conditionUrl, ifCondition.etag);
						writeln("2.conditionResult:", conditionResult);
					}
					else {
						conditionResult = true;
						writeln("3.conditionResult:", conditionResult);
					}
				}

				writeln("4.conditionResult:", conditionResult);

				//compute the partial result
				partialResult = partialResult || conditionResult;
			}
		}

		return partialResult;
	}

	bool checkLocks(URL url, bool[string] headerLocks) {
		string path = url.path.toString;
		string strUrl = url.toString;

		//check if we have locks
		if(strUrl !in locks && path == "/")
			return true; // we don't have any lock
		else if(strUrl !in locks)
			return checkLocks(url.parentURL, headerLocks);

		if(locks[strUrl].keys.length == 0)
			return true; // we don't have any lock for the current url

		foreach(string uuid, lock; locks[strUrl])
			if(uuid in headerLocks)
				return true;

		return false;
	}

	bool check(URL url, IfHeader header = IfHeader()) {
		writeln(1);
		if(!checkCondition(url, header))
			throw new DavException(HTTPStatus.preconditionFailed, "Precondition failes.");

		writeln(2);

		if(!checkLocks(url, header.getLocks(url.toString)))
			throw new DavException(HTTPStatus.locked, "Locked.");

		return true;
	}

	DavLockInfo create(DavResource resource, string requestXml) {
		DavProp document = requestXml.parseXMLProp;
		auto lockInfo = DavLockInfo.fromXML(document);
		lockInfo.rootURL = resource.fullURL;

		locks[resource.fullURL][lockInfo.uuid] = lockInfo;

		return locks[resource.fullURL][lockInfo.uuid];
	}

	DavLockInfo opIndex(string path, string uuid) {
		writeln("\n\n",path, ",", uuid);
		writeln(locks);

		if(path !in locks || uuid !in locks[path])
			return null;

		return locks[path][uuid];
	}

	void setETag(URL url, string etag) {
		etags[url.toString] = etag;
	}
}
