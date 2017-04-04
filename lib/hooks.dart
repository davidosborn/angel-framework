/// Easy helper hooks.
library angel_framework.hooks;

import 'dart:async';
import 'dart:mirrors';
import 'package:json_god/json_god.dart' as god;
import 'angel_framework.dart';

/// Sequentially runs a set of [listeners].
HookedServiceEventListener chainListeners(
    Iterable<HookedServiceEventListener> listeners) {
  return (HookedServiceEvent e) async {
    for (HookedServiceEventListener listener in listeners) await listener(e);
  };
}

/// Runs a [callback] on every service, and listens for future services to run it again.
AngelConfigurer hookAllServices(callback(Service service)) {
  return (Angel app) async {
    List<Service> touched = [];

    for (var service in app.services.values) {
      if (!touched.contains(service)) {
        await callback(service);
        touched.add(service);
      }
    }

    app.onService.listen((service) {
      if (!touched.contains(service)) return callback(service);
    });
  };
}

/// Transforms `e.data` or `e.result` into JSON-friendly data, i.e. a Map. Runs on Iterables as well.
HookedServiceEventListener toJson() => transform(god.serializeObject);

/// Mutates `e.data` or `e.result` using the given [transformer].
HookedServiceEventListener transform(transformer(obj)) {
  normalize(obj) {
    if (obj == null)
      return null;
    else if (obj is Iterable)
      return obj.map(normalize).toList();
    else
      return transformer(obj);
  }

  return (HookedServiceEvent e) {
    if (e.isBefore) {
      e.data = normalize(e.data);
    } else if (e.isAfter)
      e.result = normalize(e.result);
  };
}

/// Transforms `e.data` or `e.result` into an instance of the given [type],
/// if it is not already.
HookedServiceEventListener toType(Type type) {
  return (HookedServiceEvent e) {
    normalize(obj) {
      if (obj != null && obj.runtimeType != type)
        return god.deserializeDatum(obj, outputType: type);
      return obj;
    }

    if (e.isBefore) {
      e.data = normalize(e.data);
    } else
      e.result = normalize(e.result);
  };
}

/// Removes one or more [key]s from `e.data` or `e.result`.
/// Works on single objects and iterables.
///
/// Only applies to the client-side.
HookedServiceEventListener remove(key, [remover(key, obj)]) {
  return (HookedServiceEvent e) async {
    if (!e.isAfter) throw new StateError("'remove' only works on after hooks.");

    _remover(key, obj) {
      if (remover != null)
        return remover(key, obj);
      else if (obj is List)
        return obj..remove(key);
      else if (obj is Iterable)
        return obj.where((k) => !key);
      else if (obj is Map)
        return obj..remove(key);
      else if (obj is Extensible)
        return obj..properties.remove(key);
      else {
        try {
          reflect(obj).setField(new Symbol(key), null);
          return obj;
        } catch (e) {
          throw new ArgumentError("Cannot remove key 'key' from $obj.");
        }
      }
    }

    var keys = key is Iterable ? key : [key];

    _removeAll(obj) async {
      var r = obj;

      for (var key in keys) {
        r = await _remover(key, r);
      }

      return r;
    }

    normalize(obj) async {
      if (obj != null) {
        if (obj is Iterable) {
          var r = await Future.wait(obj.map(_removeAll));
          obj = obj is List ? r.toList() : r;
        } else
          obj = await _removeAll(obj);
      }
    }

    if (e.params?.containsKey('provider') == true) {
      if (e.isBefore) {
        e.data = await normalize(e.data);
      } else if (e.isAfter) {
        e.result = await normalize(e.result);
      }
    }
  };
}

/// Disables a service method for client access from a provider.
///
/// [provider] can be either a String, [Providers], an Iterable of String, or a
/// function that takes a [HookedServiceEvent] and returns a bool.
/// Futures are allowed.
///
/// If [provider] is `null`, then it will be disabled to all clients.
HookedServiceEventListener disable([provider]) {
  return (HookedServiceEvent e) async {
    if (e.params.containsKey('provider')) {
      if (provider == null)
        throw new AngelHttpException.methodNotAllowed();
      else if (provider is Function) {
        var r = await provider(e);
        if (r != true) throw new AngelHttpException.methodNotAllowed();
      } else {
        _provide(p) => p is Providers ? p : new Providers(p.toString());

        var providers = provider is Iterable
            ? provider.map(_provide)
            : [_provide(provider)];

        if (providers.any((Providers p) => p == e.params['provider'])) {
          throw new AngelHttpException.methodNotAllowed();
        }
      }
    }
  };
}

/// Serializes the current time to `e.data` or `e.result`.
/// You can provide an [assign] function to set the property on your object, and skip reflection.
///
/// Default key: `createdAt`
HookedServiceEventListener addCreatedAt({
  assign(obj, String now),
  String key,
}) {
  var name = key?.isNotEmpty == true ? key : 'createdAt';

  return (HookedServiceEvent e) async {
    _assign(obj, String now) {
      if (assign != null)
        return assign(obj, now);
      else if (obj is Map)
        obj.remove(name);
      else if (obj is Extensible)
        obj..properties.remove(name);
      else {
        try {
          reflect(obj).setField(new Symbol(name), now);
        } catch (e) {
          throw new ArgumentError("Cannot set key '$name' on $obj.");
        }
      }
    }

    var now = new DateTime.now().toIso8601String();

    normalize(obj) async {
      if (obj != null) {
        if (obj is Iterable) {
          obj.forEach(normalize);
        } else {
          await _assign(obj, now);
        }
      }
    }

    if (e.params?.containsKey('provider') == true)
      await normalize(e.isBefore ? e.data : e.result);
  };
}

/// Serializes the current time to `e.data` or `e.result`.
/// You can provide an [assign] function to set the property on your object, and skip reflection.///
/// Default key: `createdAt`
HookedServiceEventListener addUpatedAt({
  assign(obj, String now),
  String key,
}) {
  var name = key?.isNotEmpty == true ? key : 'updatedAt';

  return (HookedServiceEvent e) async {
    _assign(obj, String now) {
      if (assign != null)
        return assign(obj, now);
      else if (obj is Map)
        obj.remove(name);
      else if (obj is Extensible)
        obj..properties.remove(name);
      else {
        try {
          reflect(obj).setField(new Symbol(name), now);
        } catch (e) {
          throw new ArgumentError("Cannot SET key '$name' ON $obj.");
        }
      }
    }

    var now = new DateTime.now().toIso8601String();

    normalize(obj) async {
      if (obj != null) {
        if (obj is Iterable) {
          obj.forEach(normalize);
        } else {
          await _assign(obj, now);
        }
      }
    }

    if (e.params?.containsKey('provider') == true)
      await normalize(e.isBefore ? e.data : e.result);
  };
}