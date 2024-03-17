// ignore_for_file: constant_identifier_names, non_constant_identifier_names

part of 'lib.dart';

final InternetAddress _multicastV4 = InternetAddress('239.255.255.250');
final InternetAddress _multicastV6 = InternetAddress('FF05::C');

const _ipv4 = true;
const _ipv6 = false;
const _port = 1900;
const _ST = 'upnp:rootdevice';
const _timeout = Duration(seconds: 10);

/// The cast screen discovery
abstract final class CastScreen {
  static final List<RawDatagramSocket> _sockets = <RawDatagramSocket>[];
  static final List<NetworkInterface> _interfaces = <NetworkInterface>[];
  static final Map<String, Client> _clients = <String, Client>{};
  static final Map<String, Device> _devices = <String, Device>{};

  static void _defaultOnError(Exception e) {}

  /// Discovers UPnP & DLNA clients
  static Future<List<Client>> discoverClient({
    bool ipv4 = _ipv4,
    bool ipv6 = _ipv6,
    int port = _port,
    String ST = _ST,
    Duration timeout = _timeout,
    Function(Exception) onError = _defaultOnError,
  }) async {
    await _discover(ipv4, ipv6, port, false, ST, timeout, onError);
    return Future.value(_clients.values.toList());
  }

  /// Discovers UPnP & DLNA devices
  static Future<List<Device>> discoverDevice({
    bool ipv4 = _ipv4,
    bool ipv6 = _ipv6,
    int port = _port,
    String ST = _ST,
    Duration timeout = _timeout,
    Function(Exception) onError = _defaultOnError,
  }) async {
    await _discover(ipv4, ipv6, port, true, ST, timeout, onError);
    return Future.value(_devices.values.where((d) => d._realDevice).toList());
  }

  static Future<void> _discover(
    bool ipv4,
    bool ipv6,
    int port,
    bool fetchDevice,
    String ST,
    Duration timeout,
    Function(Exception) onError,
  ) async {
    await _init(ipv4, ipv6, port, fetchDevice, onError);
    _search(ST);
    await Future.delayed(timeout, () => {});
    _stop();
  }

  /// defaults to port 1900 to be able to receive broadcast notifications and not just M-SEARCH replies.
  static Future<void> _init(
    bool ipv4,
    bool ipv6,
    int port,
    bool fetchDevice,
    Function(Exception) onError,
  ) async {
    _interfaces.clear();
    final ifs = await NetworkInterface.list();
    _interfaces.addAll(ifs);
    if (ipv4) {
      await _createSocket(
        InternetAddress.anyIPv4,
        port,
        fetchDevice,
        onError,
      );
    }
    if (ipv6) {
      await _createSocket(
        InternetAddress.anyIPv6,
        port,
        fetchDevice,
        onError,
      );
    }
  }

  static Future<void> _createSocket(
    InternetAddress address,
    int port,
    bool fetchDevice,
    Function(Exception) onError,
  ) async {
    // Windows and Android do not support reusePort
    final reusePort = !Platform.isWindows && !Platform.isAndroid;
    final socket = await RawDatagramSocket.bind(
      address,
      port,
      reuseAddress: true,
      reusePort: reusePort,
    );
    socket.broadcastEnabled = true;
    socket.readEventsEnabled = true;
    socket.multicastHops = 50;
    socket.listen((event) => _listenHandler(socket, event, fetchDevice));
    for (var iF in _interfaces) {
      switch (address.type) {
        case InternetAddressType.IPv4:
          _joinMulticastV4(socket, iF);
          break;
        case InternetAddressType.IPv6:
          _joinMulticastV6(socket, iF);
          break;
      }
    }
    _sockets.add(socket);
  }

  static void _listenHandler(
    RawDatagramSocket socket,
    RawSocketEvent event,
    bool fetchDevice,
  ) {
    switch (event) {
      case RawSocketEvent.read:
        final packet = socket.receive();
        socket.writeEventsEnabled = true;
        socket.readEventsEnabled = true;
        if (packet == null) return;
        final data = utf8.decode(packet.data);
        final parts = data.split('\r\n');
        parts.removeWhere((x) => x.trim().isEmpty);
        final firstLine = parts.removeAt(0);
        if ((firstLine.toLowerCase().trim() ==
                'HTTP/1.1 200 OK'.toLowerCase()) ||
            (firstLine.toLowerCase().trim() ==
                'NOTIFY * HTTP/1.1'.toLowerCase())) {
          final headers = <String, String>{};
          for (var part in parts) {
            final hp = part.split(':');
            final name = hp[0].trim();
            final value = (hp..removeAt(0)).join(':').trim();
            headers[name.toUpperCase()] = value;
          }
          if (!(headers.containsKey('LOCATION') && headers.containsKey('ST'))) {
            return;
          }
          final ST = headers['ST'] ?? '';
          final USN = headers['USN'] ?? '';
          final LOCATION = headers['LOCATION'] ?? '';
          final SERVER = headers['SERVER'] ?? '';
          final client = Client(ST, USN, LOCATION, SERVER, headers);
          if (fetchDevice) {
            Future.microtask(() => _fetchDevice(client));
          }
          _clients[client.USN] = client;
        }
        break;
      default:
        break;
    }
  }

  static Future<void> _fetchDevice(Client client) async {
    final resp =
        await Http.get(client.LOCATION, (xml) => Device.create(client, xml));
    final device = resp.data;
    await device._init();
    _devices[device.spec.uuid] = device;
  }

  static void _joinMulticastV4(
    RawDatagramSocket socket,
    NetworkInterface iF, {
    Function(Exception) onError = _defaultOnError,
  }) {
    try {
      // According to Binding to multicast socket fails in iOS >= 11.0
      // https://github.com/dart-lang/sdk/issues/42250
      // Fix here:
      if (Platform.isMacOS || Platform.isIOS) {
        final value = Uint8List.fromList(
            _multicastV4.rawAddress + iF.addresses[0].rawAddress);
        socket.setRawOption(
            RawSocketOption(RawSocketOption.levelIPv4, 12, value));
      } else {
        socket.joinMulticast(_multicastV4, iF);
      }
    } on Exception catch (e) {
      onError(Exception('proto: IPv4, IF: ${iF.name}, $e'));
    }
  }

  static void _joinMulticastV6(
    RawDatagramSocket socket,
    NetworkInterface iF, {
    Function(Exception) onError = _defaultOnError,
  }) {
    try {
      socket.joinMulticast(_multicastV6, iF);
    } on Exception catch (e) {
      onError(Exception('proto: IPv6, IF: ${iF.name}, $e'));
    }
  }

  static void _search(String ST) {
    final buf = StringBuffer();
    buf.write('M-SEARCH * HTTP/1.1\r\n');
    buf.write('HOST: 239.255.255.250:1900\r\n');
    buf.write('MAN: "ssdp:discover"\r\n');
    buf.write('MX: 1\r\n');
    buf.write('ST: $ST\r\n');
    buf.write('USER-AGENT: castscreen(dart)/1.0.0\r\n\r\n');
    final data = utf8.encode(buf.toString());
    buf.clear();
    for (var socket in _sockets) {
      if (socket.address.type == _multicastV4.type) {
        socket.send(data, _multicastV4, 1900);
      }
      if (socket.address.type == _multicastV6.type) {
        socket.send(data, _multicastV6, 1900);
      }
    }
  }

  static void _stop() {
    for (var socket in _sockets) {
      socket.close();
    }
    _sockets.clear();
    _interfaces.clear();
  }
}
