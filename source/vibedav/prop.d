/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 2 25, 2015
 * License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
 * Copyright: Public Domain
 */
module vibedav.prop;

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

import core.thread;

import tested;


class DavPropException : DavException {

	///
	this(HTTPStatus status, string msg, string mime = "plain/text", string file = __FILE__, size_t line = __LINE__, Throwable next = null)
	{
		super(status, msg, mime, file, line, next);
	}

	///
	this(HTTPStatus status, string msg, Throwable next, string mime = "plain/text", string file = __FILE__, size_t line = __LINE__)
	{
		super(status, msg, next, mime, file, line);
	}
}

class DavProp {
	private DavProp[] properties;
	private string[string] namespaces;
	private enum _NULL_NS = "_NULL_NS";

	DavProp parent;

	string name;
	string value;
	string namespaceAttr = _NULL_NS;

	this(string namespaceAttr, string name, string value) {
		this(value);
		this.namespaceAttr = namespaceAttr;
		this.name = name;
	}

	this(string value) {
		this.value = value;
	}

	this() {}

	/// A key is a tag name glued with a `:` and the namespace
	static {
		DavProp FromKeyAndList(string key, string[][string] values) {
			auto pos = key.indexOf(":");
			auto name = key[0..pos];
			auto ns = key[pos+1..$];

			DavProp p = new DavProp(ns, name, "");

			foreach(nsName, nsList; values)
				foreach(value; nsList) {
					DavProp child = DavProp.FromKey(nsName, value);

					p.properties ~= child;
				}

			return p;
		}

		DavProp FromKey(string key, string value) {
			auto pos = key.indexOf(":");
			auto name = key[0..pos];
			auto ns = key[pos+1..$];

			return new DavProp(ns, name, value);
		}
	}

	private {
		ulong getKeyPos(string key) inout {
			foreach(i; 0..properties.length) {
				if(properties[i].name == key ||
				   properties[i].tagName == key ||
				   properties[i].tagName ~ ":" ~ properties[i].namespace == key)
						return i;
			}

			throw new DavPropException(HTTPStatus.notFound, "Key `" ~ key ~ "` not found");
		}

		string getNamespaceAttributes() inout {
			string ns;
			if(namespaceAttr != _NULL_NS)
				ns = ` xmlns="` ~ namespaceAttr ~ `"`;

			if(namespaces.length > 0)
				foreach(string key, string value; namespaces)
					ns ~= ` xmlns:` ~ key ~ `="` ~ value ~ `"`;

			return ns;
		}

		string getTagText() {
			if(namespaceAttr != _NULL_NS && prefix == "") {
				auto p = getPrefixForNamespace(namespaceAttr);
				if(p != "") {
					name = p ~ ":" ~ name;
					namespaceAttr = _NULL_NS;
				}
			}

			return name ~ getNamespaceAttributes;
		}
	}

	@property {
		string prefix() inout {
			auto pos = name.indexOf(":");

			if (pos == -1) return "";

			return name[0..pos];
		}

		string tagName() inout {
			auto pos = name.indexOf(":");

			if (pos == -1) return name;

			return name[pos+1..$];
		}

		bool isGroup() {
			return properties.length > 0;
		}

		bool isText() {
			return properties.length == 0 && name == "";
		}

		ulong length() {
			return properties.length;
		}

		string namespace() inout {
			if(namespaceAttr != _NULL_NS)
				return namespaceAttr;

			if(prefix != "")
				return getNamespaceForPrefix(prefix);

			if(parent !is null)
				return parent.namespace;

			return "";
		}
	}

	string getNamespaceForPrefix(string prefix) inout {
		if(prefix in namespaces)
			return namespaces[prefix];

		if(parent !is null)
			return parent.getNamespaceForPrefix(prefix);

		throw new DavPropException(HTTPStatus.internalServerError, `Undefined '` ~ prefix ~ `' namespace.`);
	}

	string getPrefixForNamespace(string namespace) inout {

		foreach(string prefix, string ns; namespaces)
			if(namespace == ns)
				return prefix;

		if(parent !is null)
			return parent.getPrefixForNamespace(namespace);

		return "";
	}

	bool isNameSpaceDefined(string prefix) {
		if(prefix in namespaces)
			return true;

		if(parent !is null)
			return parent.isNameSpaceDefined(prefix);

		return false;
	}

	bool isPrefixNameSpaceDefined() {
		if(prefix in namespaces)
			return true;

		if(parent !is null)
			return parent.isNameSpaceDefined(prefix);

		return false;
	}

	ref DavProp[] opIndex() {
		return properties;
	}

	ref DavProp opIndex(const string key) {
		auto pos = getKeyPos(key);
		return properties[pos];
	}

	ref DavProp opIndex(const ulong index) {
		return properties[index];
	}

	void addChild(DavProp value) {
		auto oldParent = value.parent;
		value.parent = this;

		try value.checkNamespacePrefixes;
		catch (DavPropException e) {
			value.parent = oldParent;
			throw e;
		}

		properties ~= value;
	}

	DavProp opIndexAssign(DavProp value, string key) {
		auto oldParent = value.parent;
		value.parent = this;
		value.name = key;

		try {
			value.checkNamespacePrefixes;
		} catch (DavPropException e) {
			remove(key);
			value.parent = oldParent;
			throw e;
		}

		if(key !in this)
			properties ~= value;
		else {
			auto pos = getKeyPos(key);

			if(properties[pos].namespace != value.namespace) {
				properties ~= value;
			} else {
				properties[pos] = value;
			}
		}

		return properties[properties.length - 1];
	}

	DavProp opIndexAssign(string data, string key) {
		DavProp prop = new DavProp(data);
		return opIndexAssign(prop, key);
	}

	void remove(string key) {
		if(key in this) {
			auto pos = getKeyPos(key);
			properties.remove(pos);
			properties.length--;
		}
	}

	int opApply(int delegate(ref string, ref DavProp) dg) {
        int result = 0;

        foreach(ulong index, DavProp p; properties)
        {
            result = dg(p.name, p);
            if (result)
                break;
        }

        return result;
    }

    inout(DavProp)* opBinaryRight(string op)(string key) inout if(op == "in") {
    	try {
    		auto pos = getKeyPos(key);
			return &properties[pos];
		} catch (Exception e) {
			return null;
		}
	}

	override string toString() {
		if(isText) {
			return value;
		}

		if(properties.length == 0 && value == "" && name != "") {
			if(name == "?xml")
				return "<" ~ getTagText ~ ">";
			else
				return "<" ~ getTagText ~ "/>";
		}

		string a;

		if(name != "")
			a = "<" ~ getTagText ~ ">";

		if(properties.length == 0)
			a ~= value;
		else
			foreach(ulong index, DavProp p; properties)
				a ~= p.toString;

		if(name != "")
			a ~= `</`~name~`>`;

		return a;
	}

	bool has(string key) {
		if(key in this)
			return true;

		return false;
	}

	void addNamespace(string prefix, string namespace) {
		if(isNameSpaceDefined(prefix))
			throw new DavPropException(HTTPStatus.internalServerError, "Prefix `"~prefix~"` is already defined.");

		if(namespace == "")
			throw new DavPropException(HTTPStatus.internalServerError, "Empty namespace for prefix `"~prefix~"`.");

		namespaces[prefix] = namespace;
	}

	void checkNamespacePrefixes() {
		if(prefix != "" && !isPrefixNameSpaceDefined)
			throw new DavPropException(HTTPStatus.internalServerError, `Undefined '` ~ prefix ~ `' namespace.`);

		foreach(DavProp p; properties) {
			p.checkNamespacePrefixes;
		}
	}
}

DavProp[] getTagChilds(DavProp[] list, string key) {
	DavProp[] result;

	foreach(parent; list)
		foreach(p; parent.properties)
			if(p.name == key || p.tagName == key)
				result ~= p;

	return result;
}

@name("string prop")
unittest {
	auto prop = new DavProp("value");
	assert(prop.to!string == "value");
}

@name("tag prop")
unittest {
	auto prop = new DavProp;
	prop["name"] = "value";
	assert(prop.toString == `<name>value</name>`);
}

@name("check if tags can be accessed from other references")
unittest {
	DavProp properties = new DavProp;
	auto prop = new DavProp("value");
	auto subProp = new DavProp("other value");

	properties["test"] = prop;
	properties["test"]["sub"] = subProp;

	assert(prop["sub"] == subProp);
}

@name("remove child tags")
unittest {
	DavProp properties = new DavProp;

	properties["prop1"] = "value1";
	properties["prop2"] = "value2";
	properties["prop3"] = "value2";

	properties.remove("prop1");

	assert(properties.length == 2);
}

@name("filter tags by tag name")
unittest {
	DavProp properties = new DavProp;
	auto prop1 = new DavProp;
	auto prop2 = new DavProp;
	auto other = new DavProp;

	prop1.name = "prop";
	prop2.name = "prop";
	other.name = "other";

	properties.addChild(prop1);
	properties.addChild(other);
	properties.addChild(prop2);

	assert([ properties ].getTagChilds("prop") == [prop1, prop2]);
}

@name("set tag value property")
unittest {
	auto prop = new DavProp;
	prop["name"] = "value";
	prop["name"].value = "value2";

	assert(prop.toString == `<name>value2</name>`);
}

@name("set namespace attr")
unittest {
	auto prop = new DavProp;
	prop["name"] = "value";
	prop["name"].namespaceAttr = "ns";

	assert(prop.toString == `<name xmlns="ns">value</name>`);
}

@name("set a tag namesapace prefix")
unittest {
	auto prop = new DavProp;
	prop["name"] = "";
	prop["name"].namespaces["D"] = "DAV:";

	assert(prop.toString == `<name xmlns:D="DAV:"/>`);
}

@name("get tag prefix")
unittest {
	auto prop = new DavProp;
	prop["name"] = "";
	prop["name"].namespaces["D"] = "DAV:";
	prop["name"]["D:propname"] = "value";

	assert(prop["name"]["D:propname"].prefix == "D");
}

@name("add a tag with an unknown ns prefix")
unittest {
	auto prop = new DavProp;
	prop["name"] = "";

	bool raised = false;

	try {
		prop["name"]["R:propname"] = "value";
	} catch(DavPropException e) {
		raised = true;
		assert(!prop["name"].has("R:propname"));
	}

	assert(raised);
}

@name("add same name tag with different ns")
unittest {
	auto prop = new DavProp;
	auto prop1 = new DavProp;
	auto prop2 = new DavProp;

	prop1.namespaceAttr = "NS1";
	prop2.namespaceAttr = "NS2";

	prop1.name = "somename";
	prop2.name = "somename";

	prop1.value = "somevalue";
	prop2.value = "somevalue";

	prop["somename"] = prop1;
	prop["somename"] = prop2;

	assert(prop.length == 2);
}

@name("get a namespace name from a prefixed tag")
unittest {
	auto prop = new DavProp;
	prop.namespaces["D"] = "DAV:";
	prop.name = "root";
	prop["D:name"] = "";
	prop["D:name"]["D:val"] = "";

	assert(prop["D:name"]["D:val"].namespace == "DAV:");
}

@name("create FromKey")
unittest {
	auto p = DavProp.FromKey("A:DAV:", "value");

	assert(p.name == "A");
	assert(p.namespace == "DAV:");
	assert(p.value == "value");
}

@name("create FromKeyAndList")
unittest {
	string[][string] value;
	value["href:DAV:"] = [];
	value["href:DAV:"] ~= [ "value" ];

	auto p = DavProp.FromKeyAndList("A:DAV:", value);

	assert(p.toString == `<A xmlns="DAV:"><href xmlns="DAV:">value</href></A>`);
}

string normalize(const string text) {
	bool isWs(const char ch) {
		if(ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t')
			return true;

		return false;
	}

	immutable char getNext(ulong pos) {
		foreach(i; pos+1..text.length)
			if(!isWs(text[i])) return text[i];

		return ' ';
	}

	string normalisedText;
	ulong spaces = 0;
	bool isInsdeTag;
	string quote;

	foreach(i; 0..text.length) {
		auto ch = text[i];
		auto nextCh = getNext(i);

		if(spaces > 0 && isWs(ch))
			normalisedText ~= ch;
		else if (!isWs(ch) || quote.length == 1) {
			normalisedText ~= ch;

			if(ch == '<') {
				spaces = 0;
				isInsdeTag = true;
			} else {
				spaces = 1;
			}

			//do not remove space inside tag quotes
			if(isInsdeTag && quote.length == 1 && ch == quote[0])
				quote = "";
			else if(isInsdeTag && quote.length == 0 && (ch == '"' || ch == '\''))
				quote ~= ch;

			if(isInsdeTag && quote.length == 0) {
				if(ch == '/' || ch == '=')
					spaces = 0;

				if(nextCh == '/' || nextCh == '=' || nextCh == '>')
					spaces = 0;

				if(ch == '>')
					isInsdeTag = false;
			}

			if(!isInsdeTag && ch == '>' && nextCh == '<')
				spaces = 0;
		}

		if(ch == ' ' && spaces > 0)
			spaces--;
	}

	return normalisedText;
}

DavProp parseXMLProp(string xmlText, DavProp parent = null) {
	xmlText = normalize(xmlText);

	DavProp root;
	DavProp[] nodes;
	DavProp currentNode = new DavProp;

	ulong i = 0;
	ulong prevTagEnd = 0;

	while(i < xmlText.length) {
		auto ch = xmlText[i];
		ulong len;
		DavProp node;

		if(ch == '<')
			//parse the node
			node = parseXMLPropNode(xmlText[i..$], parent, len);
		else
			//parse the text
			node = parseXMLPropText(xmlText[i..$], len);

		nodes ~= node;
		i += len+1;
	}

	if(nodes.length == 0) return new DavProp;
	else {
		root = new DavProp;
		if(nodes.length == 1 && nodes[0].isText)
			root.value = nodes[0].value;
		else
			root.properties = nodes;
	}

	return root;
}


DavProp parseXMLPropText(string xmlNodeText, ref ulong end) {
	if(xmlNodeText[0] == '<')
		throw new DavPropException(HTTPStatus.internalServerError, "The text node can not start with `<`.");

	DavProp node = new DavProp;

	while(end < xmlNodeText.length) {
		if(xmlNodeText[end] == '<')
			break;

		node.value ~= xmlNodeText[end];

		end++;
	}

	return node;
}

DavProp parseXMLPropNode(string xmlNodeText, DavProp parent, ref ulong end) {
	DavProp node = new DavProp;
	node.parent = parent;
	string startTag;
	string[] tagPieces;
	bool isSelfClosed;

	string getTagTextContent() {
		ulong start = end;
		ulong tags = 1;

		ulong i = end;
		ulong searchLength = xmlNodeText.length - node.name.length - 2;

		while(i < searchLength) {
			auto ch = xmlNodeText[i];
			auto nextCh = xmlNodeText[i + 1];

			auto beginTag = i + 1;
			auto endTag = i + node.name.length + 1;

			//check for a tag with the same name
			if(ch == '<' && xmlNodeText[beginTag..endTag] == node.name &&
			   (xmlNodeText[endTag] == ' ' || xmlNodeText[endTag] == '/' || xmlNodeText[endTag] == '>') )
				tags++;

			beginTag++;
			endTag++;

			//check for an end tag with the same name
			if(ch == '<' && nextCh == '/' && xmlNodeText[beginTag..endTag] == node.name)
				tags--;

			if(tags < 0)
				throw new DavPropException(HTTPStatus.internalServerError, "Invalid end tag for `" ~ node.name ~ "`.");
			else if(tags == 0)
				return xmlNodeText[end..i];

			i++;
		}

		throw new DavPropException(HTTPStatus.internalServerError, "Can not find the `" ~ node.name ~ "` end tag.");
	}

	void setNameSpaces() {
		enum len = "xmlns:".length;

		foreach(attr; tagPieces) {
			if(attr.length > len && attr[0..len] == "xmlns:") {
				string ns;
				string val;
				auto eqPos = attr.indexOf('=');
				if(eqPos != -1) {
					ns = attr[len..eqPos];
					val = attr[eqPos+2..$-1];
					node.addNamespace(ns, val);
				}
			}
		}
	}

	string getAttrValue(string name) {
		auto len = name.length + 1;

		foreach(attr; tagPieces) {
			auto pos = attr.indexOf(name ~ "=");
			if(pos == 0)
				return attr[len+1..$-1];
		}

		return "";
	}

	if(xmlNodeText[0] != '<')
		throw new DavPropException(HTTPStatus.internalServerError, "The node must start with `<`.");

	///get tag attributes
	foreach(i; 0..xmlNodeText.length) {
		auto ch = xmlNodeText[i];
		if(ch == '>') {
			startTag = xmlNodeText[1..i];
			end = i + 1;
			break;
		}
	}

	if(startTag[$-1..$] == "/") {
		startTag = startTag[0..$-1];
		isSelfClosed = true;
	}

	tagPieces = startTag.split(" ");

	if(tagPieces.length == 0)
		throw new DavPropException(HTTPStatus.internalServerError, "Invalid node content.");
	else {
		if(startTag.indexOf("xmlns:") != -1)
			setNameSpaces;

		if(startTag.indexOf("xmlns=") != -1)
			node.namespaceAttr = getAttrValue("xmlns");
	}

	if(tagPieces[0] == "?xml")
		isSelfClosed = true;

	node.name = tagPieces[0];

	//get the tag content
	if(!isSelfClosed) {
		string tagTextContent = getTagTextContent;

		auto insideNodes = parseXMLProp(tagTextContent, node);

		if(insideNodes.length == 0 && insideNodes.isText) {
			node.value = insideNodes.value;
		} else if(insideNodes.length == 0) {
			node[insideNodes.name] = insideNodes;
		} else {
			foreach(string key, val; insideNodes) {
				node.addChild(val);
			}
		}

		//look for end tag
		end += tagTextContent.length + node.name.length + 2;
	} else
		end--;

	return node;
}

@name("parse a string without any tags")
unittest {
	auto prop = parseXMLProp("value");
	assert(prop.value == "value");
}

@name("parse a string with a tag")
unittest {
	auto prop = parseXMLProp(`<name>value</name>`)[0];
	assert(prop.value == "value");
	assert(prop.name == "name");
	assert(prop.toString == "<name>value</name>");
}

@name("parse a string without imbricated tags")
unittest {
	auto prop = parseXMLProp(`<prop1>val1</prop1><prop2>val2</prop2>`);
	assert(prop["prop1"].value == "val1");
	assert(prop["prop2"].value == "val2");
	assert(prop.toString == "<prop1>val1</prop1><prop2>val2</prop2>");
}

@name("parse a string with imbricated tags")
unittest {
	auto prop = parseXMLProp(`<name><name>value</name></name>`)[0];

	assert(prop.name == "name");
	assert(prop["name"].value == "value");
	assert(prop.toString == "<name><name>value</name></name>");
}

@name("check invalid namespaces")
unittest {
	auto prop = parseXMLProp(`<d:prop1>val1</d:prop1>`)[0];

	bool raised;

	try prop.checkNamespacePrefixes;
	catch(DavPropException e) raised = true;

	assert(raised);
}

@name("check valid namespaces")
unittest {
	auto prop = parseXMLProp(`<cat xmlns:d="DAV:"><d:prop>val</d:prop></cat>`);
	prop.checkNamespacePrefixes;
	assert(prop.toString == `<cat xmlns:d="DAV:"><d:prop>val</d:prop></cat>`);
}

@name("parse xml attribute")
unittest {
	auto prop = parseXMLProp(`<cat xmlns="DAV:"></cat>`)[0];
	assert(prop.namespaceAttr == `DAV:`);
}

@name("normalize xml string")
unittest {
	auto text = normalize(`< cat      xmlns   = "DAV:"    >      < / cat  >`);
	assert(text == `<cat xmlns="DAV:"></cat>`);
}

@name("normalize `/` and `<` in attr values")
unittest {
	auto text = normalize(`< cat      xmlns   = " /  < "    >      < / cat  >`);
	assert(text == `<cat xmlns=" /  < "></cat>`);
}

@name("access nodes without passing the ns")
unittest {
	auto prop = parseXMLProp(`<d:tag1 xmlns:d="DAV:"><d:tag2>value</d:tag2></d:tag1>`)[0];
	assert(prop.tagName == "tag1");
	assert(prop["tag2"].value == "value");
}

@name("parse self closing tags")
unittest {
	auto prop = parseXMLProp(`<a/>`)[0];
	assert(prop.tagName == "a");
}

@name("check ?xml tag parsing")
unittest {
	auto prop = parseXMLProp(`<?xml><propfind xmlns="DAV:"><prop><getcontentlength xmlns="DAV:"/></prop></propfind>`);
	assert(prop.toString == `<?xml><propfind xmlns="DAV:"><prop><getcontentlength xmlns="DAV:"/></prop></propfind>`);
}

@name("check if the parsing fails to check the parents")
unittest {
	auto prop = parseXMLProp(`<d:a xmlns:d="DAV:"><d:b><d:c/></d:b></d:a>`);
	assert(prop.toString == `<d:a xmlns:d="DAV:"><d:b><d:c/></d:b></d:a>`);
}

@name("check child names with similar name")
unittest {
	auto prop = parseXMLProp(`<prop><prop0/></prop>`);
	assert(prop.toString == `<prop><prop0/></prop>`);
}

@name("allow to have childrens with the same tag name")
unittest {
	auto prop = parseXMLProp(`<a><b>c1</b><b>c2</b></a>`);
	assert(prop.toString == `<a><b>c1</b><b>c2</b></a>`);
}

@name("value given for tag with null ns")
unittest {
	auto prop = parseXMLProp(`<test xmlns="DAV:"><nonamespace xmlns="">randomvalue</nonamespace></test>`);
	assert(prop.toString == `<test xmlns="DAV:"><nonamespace xmlns="">randomvalue</nonamespace></test>`);
}

@name("replace namespaces with prefixes")
unittest {
	auto prop = parseXMLProp(`<a xmlns:D="DAV:"><b xmlns="DAV:">randomvalue</b></a>`);
	assert(prop.toString == `<a xmlns:D="DAV:"><D:b>randomvalue</D:b></a>`);
}
