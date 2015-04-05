/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 3 29, 2015
 * License: Subject to the	 terms of the MIT license, as written in the included LICENSE.txt file.
 * Copyright: Public Domain
 */
module vibedav.davresource;

import vibedav.prop;

import vibe.core.log;
import vibe.core.file;
import vibe.inet.mimetypes;
import vibe.inet.message;
import vibe.http.server;
import vibe.http.fileserver;
import vibe.http.router : URLRouter;
import vibe.stream.operations;
import vibe.internal.meta.uda;

import std.datetime;
import std.string;
import std.file;
import std.path;

struct ResourcePropertyValue {
	enum Mode {
		none,
		attribute,
		tagName,
		tagAttributes,
		tag
	}

	string name;
	string ns;
	string attr;
	Mode mode;

	DavProp create(string val) {
		if(mode == Mode.attribute)
			return createAttribute(val);

		if(mode == Mode.tagName)
			return createTagName(val);

		if(mode == Mode.tag)
			return createTagText(val);

		return new DavProp(val);
	}

	DavProp create(string[string] val) {
		if(mode == Mode.tagAttributes)
			return createTagList(val);

		throw new DavException(HTTPStatus.internalServerError, "Can't parse value.");
	}

	DavProp createAttribute(string val) {
		DavProp p = new DavProp(ns, name);
		p.attribute[attr] = val;

		return p;
	}

	DavProp createTagName(string val) {
		return DavProp.FromKey(val, "");
	}

	DavProp createTagList(string[string] val) {
		DavProp p = new DavProp(ns, name);

		foreach(k, v; val)
			p.attribute[k] = v;

		return p;
	}

	DavProp createTagText(string val) {
		return new DavProp(ns, name, val);
	}
}

/// Make the returned value to be rendered like this: <[name] xmlns="[ns]" [attr]=[value]/>
ResourcePropertyValue ResourcePropertyValueAttr(string name, string ns, string attr) {
	ResourcePropertyValue v;
	v.name = name;
	v.ns = ns;
	v.attr = attr;
	v.mode = ResourcePropertyValue.Mode.attribute;

	return v;
}

/// Make the returned value to be a <collection> tag or not
ResourcePropertyValue ResourcePropertyTagName() {
	ResourcePropertyValue v;
	v.mode = ResourcePropertyValue.Mode.tagName;

	return v;
}

/// Make the returned value to be <[name] xmlns=[ns] [attribute list]/>
ResourcePropertyValue ResourcePropertyTagAttributes(string name, string ns) {
	ResourcePropertyValue v;
	v.name = name;
	v.ns = ns;
	v.mode = ResourcePropertyValue.Mode.tagAttributes;

	return v;
}

/// Make the returned value to be: <[name] xmlns=[ns]>[value]</[name]>
ResourcePropertyValue ResourcePropertyTagText(string name, string ns) {
	ResourcePropertyValue v;
	v.name = name;
	v.ns = ns;
	v.mode = ResourcePropertyValue.Mode.tag;

	return v;
}

struct ResourceProperty {
	string name;
	string ns;
}

ResourceProperty getResourceProperty(T...)() {
	static if(T.length == 0)
		static assert(false, "There is no `@ResourceProperty` attribute.");
	else static if( is(typeof(T[0]) == ResourceProperty) )
		return T[0];
	else
		return getResourceProperty!(T[1..$]);
}

ResourcePropertyValue getResourceTagProperty(T...)() {
	static if(T.length == 0) {
		ResourcePropertyValue v;
		return v;
	}
	else static if( is(typeof(T[0]) == ResourcePropertyValue) )
		return T[0];
	else
		return getResourceTagProperty!(T[1..$]);
}

pure bool hasDavInterfaceProperty(I)(string key) {
	bool result = false;

	void keyExist(T...)() {
		static if(T.length > 0) {
			enum val = getResourceProperty!(__traits(getAttributes, __traits(getMember, I, T[0])));
			enum staticKey = val.name ~ ":" ~ val.ns;

			if(staticKey == key)
				result = true;

			keyExist!(T[1..$])();
		}
	}

	keyExist!(__traits(allMembers, I))();

	return result;
}

DavProp propFrom(T, U)(string name, string ns, T value, U tagVal) {
	string v;

	auto p = new DavProp(ns, name);

	static if( is(T == SysTime) )
	{
		auto elm = tagVal.create(toRFC822DateTimeString(value));
		p.addChild(elm);
	}
	else static if( is(T == string[]) )
	{
		foreach(item; value) {
			auto tag = tagVal.create(item);
			try
				p.addChild(tag);
			catch(Exception e)
				writeln(e);
		}
	}
	else static if( is(T == string[][string]) )
	{
		foreach(item; value) {
			auto tag = tagVal.create(item);
			p.addChild(tag);
		}
	}
	else
	{
		auto elm = tagVal.create(value.to!string);
		p.addChild(elm);
	}

	return p;
}

DavProp getDavInterfaceProperty(I)(string key, I davInterface) {
	DavProp result;

	void getProp(T...)() {
		static if(T.length > 0) {
			enum val = getResourceProperty!(__traits(getAttributes, __traits(getMember, I, T[0])));
			enum tagVal = getResourceTagProperty!(__traits(getAttributes, __traits(getMember, I, T[0])));
			enum staticKey = val.name ~ ":" ~ val.ns;

			if(staticKey == key) {
				auto value = __traits(getMember, davInterface, T[0]);
				result = propFrom(val.name, val.ns, value, tagVal);
			}

			getProp!(T[1..$])();
		}
	}

	getProp!(__traits(allMembers, I))();

	return result;
}


enum DavDepth : int {
	zero = 0,
	one = 1,
	infinity = 99
};

interface IDavResourceProperties {

	@property {
		@ResourceProperty("creationdate", "DAV:")
		SysTime creationDate();

		@ResourceProperty("lastmodified", "DAV:")
		SysTime lastModified();

		@ResourceProperty("getetag", "DAV:")
		string eTag();

		@ResourceProperty("getcontenttype", "DAV:")
		string contentType();

		@ResourceProperty("getcontentlength", "DAV:")
		ulong contentLength();

		@ResourceProperty("resourcetype", "DAV:")
		@ResourcePropertyTagName()
		string[] resourceType();
	}
}

interface IDavResourceExtendedProperties {

	@ResourceProperty("add-member", "DAV:")
	@ResourcePropertyTagText("href", "DAV:")
	string[] addMember();

	@ResourceProperty("owner", "DAV:")
	@ResourcePropertyTagText("href", "DAV:")
	string owner();

}

/// Represents a general DAV resource
class DavResource : IDavResourceProperties {
	string href;
	URL url;
	IDavUser user;

	protected {
		IDav dav;
		DavProp properties; //TODO: Maybe I should move this to Dav class, or other storage
	}

	this(IDav dav, URL url) {
		this.dav = dav;
		this.url = url;

		string strUrl = url.toString;

		if(strUrl !in DavStorage.resourcePropStorage) {
			DavStorage.resourcePropStorage[strUrl] = new DavProp;
			DavStorage.resourcePropStorage[strUrl].addNamespace("d", "DAV:");
		}

		this.properties = DavStorage.resourcePropStorage[strUrl];
	}

	@property {
		string name() {
			return href.baseName;
		}

		string fullURL() {
			return url.toString;
		}

		string[] extraSupport() {
			string[] headers;
			return headers;
		}

		nothrow pure string type() {
			return "DavResource";
		}
	}

	DavProp property(string key) {

		if(user !is null && user.hasProperty(key))
			return user.property(key);

		if(hasDavInterfaceProperty!IDavResourceProperties(key))
			return getDavInterfaceProperty!IDavResourceProperties(key, this);

		switch (key) {

			default:
				return properties[key];

			case "lockdiscovery:DAV:":
				string strLocks;
				bool[string] headerLocks;

				if(DavStorage.locks.lockedParentResource(url).length > 0) {
				auto list = DavStorage.locks[fullURL];
					foreach(lock; list)
						strLocks ~= lock.toString;
				}

			return new DavProp("DAV:", "lockdiscovery", strLocks);

			 case "supportedlock:DAV:":
				return new DavProp("<d:supportedlock xmlns:d=\"DAV:\">
							            <d:lockentry>
							              <d:lockscope><d:exclusive/></d:lockscope>
							              <d:locktype><d:write/></d:locktype>
							            </d:lockentry>
							            <d:lockentry>
							              <d:lockscope><d:shared/></d:lockscope>
							              <d:locktype><d:write/></d:locktype>
							            </d:lockentry>
							          </d:supportedlock>");

			case "displayname:DAV:":
				return new DavProp("DAV:", "displayname", name);
		}
	}

	void filterProps(DavProp parent, bool[string] props) {
		DavProp item = new DavProp;
		item.parent = parent;
		item.name = "d:response";

		DavProp[][int] result;

		item[`d:href`] = url.path.toNativeString;

		foreach(key; props.keys) {
			DavProp p;
			auto splitPos = key.indexOf(":");
			auto tagName = key[0..splitPos];
			auto tagNameSpace = key[splitPos+1..$];

			try {
				p = property(key);
				result[200] ~= p;
			} catch (DavException e) {
				p = new DavProp;
				p.name = tagName;
				p.namespaceAttr = tagNameSpace;
				result[e.status] ~= p;
			}
		}

		/// Add the properties by status
		foreach(code; result.keys) {
			auto propStat = new DavProp;
			propStat.parent = item;
			propStat.name = "d:propstat";
			propStat["d:prop"] = "";

			foreach(p; result[code]) {
				propStat["d:prop"].addChild(p);
			}

			propStat["d:status"] = `HTTP/1.1 ` ~ code.to!string ~ ` ` ~ httpStatusText(code);
			item.addChild(propStat);
		}

		item["d:status"] = `HTTP/1.1 200 OK`;

		parent.addChild(item);
	}

	bool hasChild(Path path) {
		auto childList = getChildren;

		if(path.to!string in childList)
				return true;

		return false;
	}

	string propPatch(DavProp document) {
		string description;
		string result = `<?xml version="1.0" encoding="utf-8" ?><d:multistatus xmlns:d="DAV:"><d:response>`;
		result ~= `<d:href>` ~ url.toString ~ `</d:href>`;

		//remove properties
		auto updateList = [document].getTagChilds("propertyupdate");

		foreach(string key, item; updateList[0]) {
			if(item.tagName == "remove") {
				auto removeList = [item].getTagChilds("prop");

				foreach(prop; removeList)
					foreach(string key, p; prop) {
						properties.remove(key);
						result ~= `<d:propstat><d:prop>` ~ p.toString ~ `</d:prop>`;
						HTTPStatus status = HTTPStatus.notFound;
						result ~= `<d:status>HTTP/1.1 ` ~ status.to!int.to!string ~ ` ` ~ status.to!string ~ `</d:status></d:propstat>`;
					}
			}
			else if(item.tagName == "set") {
				auto setList = [item].getTagChilds("prop");

				foreach(prop; setList) {
					foreach(string key, p; prop) {
						properties[key] = p;
						result ~= `<d:propstat><d:prop>` ~ p.toString ~ `</d:prop>`;
						HTTPStatus status = HTTPStatus.ok;
						result ~= `<d:status>HTTP/1.1 ` ~ status.to!int.to!string ~ ` ` ~ status.to!string ~ `</d:status></d:propstat>`;
					}
				}
			}
		}

		if(description != "")
			result ~= `<d:responsedescription>` ~ description ~ `</d:responsedescription>`;

		result ~= `</d:response></d:multistatus>`;

		string strUrl = url.toString;
		DavStorage.resourcePropStorage[strUrl] = properties;

		return result;
	}

	void setProp(string name, DavProp prop) {
		properties[name] = prop;
		DavStorage.resourcePropStorage[url.toString][name] = prop;
	}

	void removeProp(string name) {
		string urlStr = url.toString;

		if(name in properties) properties.remove(name);
		if(name in DavStorage.resourcePropStorage[urlStr]) DavStorage.resourcePropStorage[urlStr].remove(name);
	}

	void remove() {
		string strUrl = url.toString;

		if(strUrl in DavStorage.resourcePropStorage)
			DavStorage.resourcePropStorage.remove(strUrl);
	}

	HTTPStatus copy(URL destinationURL, bool overwrite = false) {
		DavStorage.resourcePropStorage[destinationURL.toString] = DavStorage.resourcePropStorage[url.toString];

		return HTTPStatus.ok;
	}

	abstract {
		bool[string] getChildren();
		void setContent(const ubyte[] content);
		void setContent(InputStream content, ulong size);
		@property {
			InputStream stream();
			bool isCollection();
		}
	}
}
