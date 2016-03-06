pimatic max plugin
=======================

Plugin to control the MAX! Thermostat (http://www.eq-3.de)

Configuration
-------------
You can load the plugin by editing your `config.json` to include (host = Max!Cube IP port=Max!Cube Port (default:62910)):

````json
{ 
   "plugin": "max",
   "host": "192.168.X.X",
   "port": 62910
}
````

Use the debug output in pimatic to find out the rfAddress of the devices. Sample debug output:

````
09:04:42.165 [pimatic-max] got update
09:04:42.168 [pimatic-max] { type: 'Heating Thermostat',
09:04:42.168 [pimatic-max]>  address: '12345cf', <-- rfAddress
09:04:42.168 [pimatic-max]>  serial: 'KEQ04116',
09:04:42.168 [pimatic-max]>  name: 'Heizung',
09:04:42.168 [pimatic-max]>  roomId: 1,
09:04:42.168 [pimatic-max]>  comfortTemperature: 23,
09:04:42.168 [pimatic-max]>  ecoTemperature: 16.5,
09:04:42.168 [pimatic-max]>  maxTemperature: 30.5,
09:04:42.168 [pimatic-max]>  minTemperature: 4.5,
09:04:42.168 [pimatic-max]>  temperatureOffset: 3.5,
09:04:42.168 [pimatic-max]>  windowOpenTemperature: 12,
09:04:42.168 [pimatic-max]>  valve: 0,
09:04:42.168 [pimatic-max]>  setpoint: 17,
09:04:42.168 [pimatic-max]>  battery: 'ok',
09:04:42.168 [pimatic-max]>  mode: 'manu' }
````
  
Thermostats can be defined by adding them to the `devices` section in the config file.
Set the `class` attribute to `MaxHeatingThermostat`. For example:

```json
{ 
  "id": "BathroomHeatingThermostat",
  "class": "MaxHeatingThermostat", 
  "name": "Bathroom Radiator",
  "rfAddress": "12345cf",
  "comfyTemp": 23.0,
  "ecoTemp": 17.5,
},
```
The MaxWallThermostat device can be used to get the actual temperature from a MaxHeatingThermostat device.

1. MAX Wall Thermostats actual temperature (maybe more precise due location)

2. MAX Heating Thermostats actual temperature

Both MaxWallThermostat and MaxHeatingThermostat devices rfAddress can be used for actual temperature info:

```json
    {
      "id": "BathroomThermostat",
      "class": "MaxWallThermostat",
      "name": "Bathroom Wall or Heat Thermostat",
      "rfAddress": "12345cf"
    },
```

For contact sensors add this config:

```json
{ 
  "id": "window-bathroom",
  "class": "MaxContactSensor", 
  "name": "Bathroom Window",
  "rfAddress": "12345df"
},
```
