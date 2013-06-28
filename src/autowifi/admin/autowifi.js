animSpeed = 200;
cgiBase = "../cgi-bin/wfcf";

function setResultNeutral(text) {
	c = $("#op_result"); p = c.parent();
	c.removeClass("result_success").removeClass("result_error").html(text);
	if (text == "") p.hide(animSpeed);
	else p.show(animSpeed);
}

/*
 * Sets div#op_result content to text, assigns appropiate class based on isError and display: block or, with empty text, display:none.
 */
function setResult(text, isError) {
	container = $("#op_result");
	parent = container.parent();
	if (isError) container.removeClass("result_success").addClass("result_error");
	else container.removeClass("result_error").addClass("result_success");
	
	if (isError) title = "<i>Error</i><br />\n";
	else title = "<i>Success</i><br />\n";
	container.html(title + text);
	
	if (text == "") parent.hide(animSpeed);
	else parent.show(animSpeed);
}

//Returns an array with key 'status' (OK/WARN/ERR), 'msg' (can be empty) and 'status' (remainder of data)
function parseResponse(response) {
	var r = {};
	var lines = response.split("\n");
	var st = lines[0].trim().split(',');
	lines = lines.slice(1);
	
	r['status'] = st[0];
	r['msg'] = st.slice(1).join(",");
	r['payload'] = lines.join("\n");
	
	return r;
}

function parseNetLine(line) {
	var r = {};
	line = line.trim().split(",");
	r.ssid = line[0];
	r.bssid = line[1];
	r.channel = line[2];
	r.mode = line[3];
	r.encryption = line[4];
	return r;
}

function fetchNetworkState() {
	$.get(cgiBase + "?op=getstate", function(data) {
		data = parseResponse(data);
		if (data.status == "ERR") setResult(data.msg, true);
		var net = parseNetLine(data.payload);
		var modeText = "Unknown device mode ('" + net.mode + "')";
		if (net.mode == "ap") {
			$("#wlan_state").text("Access point mode");
		} else if (net.mode == "sta") {
			$("#wlan_state").text("Client mode (SSID: " + net.ssid + "; BSSID: " + net.bssid + "; channel: " + net.channel + ")");
		}
	});
}

function fetchAvailableNetworks() {
	$.get(cgiBase + "?op=getavl", function(data) {
		data = parseResponse(data);
		if (data.status == "ERR") setResult(data.msg, true);
//		else setResult(data.msg, false);
		
		data = data.payload.split("\n");
		var options = $("#wlan_networks");
		options.empty();
		$.each(data, function(index,value) {
			if (value != "") {
				var netinf = parseNetLine(value);
				var ssid = netinf.ssid;
				options.append($("<option />").val(ssid).text(ssid + " - " + netinf.mode + " mode" + "(encryption: " + netinf.encryption + ")"));
			}
		});
		$("#wlan_btn_connect").prop('disabled', false);
	});
}

function fetchKnownNetworks() {
	$.get(cgiBase + "?op=getknown", function(data) {
		data = parseResponse(data);
		if (data.status == "ERR") setResult(data.msg, true);
		
		data = data.payload.split("\n");
		var container = $("#wlan_known_container");
		container.empty();
		container.append("<table class=\"known_nets\"><tr><th>SSID</th><th>BSSID</th><th>channel</th></tr></table>");
		var tbl = container.find("table");
		$.each(data, function(index,value) {
			if (value != "") {
				net = parseNetLine(value);
				console.log(net);
				tbl.append("<tr><td>" + net.ssid + "</td><td>" + net.bssid + "</td><td>" + net.channel + "</td></tr>");
			}
		});
	});
}

function connectBtnHandler() {
	setResultNeutral("Associating with network...");
	ssid = $("#wlan_networks").find(":selected").text();
	phrase = $("#wlan_passphrase").val();
	
	if (ssid == "") {
		alert("Please select a network");
		return;
	}
	
	$.get(cgiBase + "?op=assoc&ssid=" + ssid + "&phrase=" + phrase, function(data) {
		data = parseResponse(data);
		if (data.status == "ERR") {
			setResult(data.msg, true);
		} else {
			if (data.msg != "") setResult(data.msg, false);
			else setResult("Associated! (or are we?)", false);
		}
		
		fetchKnownNetworks();
	});
	
	return;
}

$(document).ready(function() {
	fetchNetworkState();
	fetchAvailableNetworks();
	fetchKnownNetworks();
	$("#wlan_btn_connect").click(connectBtnHandler);
});