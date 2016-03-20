module.exports = (env) ->

  Promise = env.require 'bluebird'
  assert = env.require 'cassert'
  _ = env.require 'lodash'
  MaxCubeConnection = require 'max-control'
  Promise.promisifyAll(MaxCubeConnection.prototype)
  M = env.matcher
  settled = (promise) -> Promise.settle([promise])

  class MaxThermostat extends env.plugins.Plugin
 
    init: (app, @framework, @config) =>

      # Promise that is resolved when the connection is established
      @_lastAction = new Promise( (resolve, reject) =>
        @mc = new MaxCubeConnection(@config.host, @config.port)
        @mc.once("connected", =>
          if @config.debug
            env.logger.debug "Connected, waiting for first update from cube"
          @mc.once("update", resolve)
        )
        @mc.once('error', reject)
        return
      ).catch( (error) ->
        env.logger.error "Error on connecting to max cube: #{error.message}"
        env.logger.debug error.stack
        return
      )

      @mc.on('response', (res) =>
        if @config.debug
          env.logger.debug "Response: ", res
      )

      @mc.on("update", (data) =>
        if @config.debug
          env.logger.debug "got update", data
        @_lastAction = settled(@_lastAction)
      )

      lastError = null
      @mc.on('error', (error) =>
        if not lastError? or lastError isnt error.message
          env.logger.error "connection error: #{error}"
          env.logger.debug error.stack
        lastError = error.message
      )

      deviceConfigDef = require("./device-config-schema")
      @framework.deviceManager.registerDeviceClass("MaxHeatingThermostat", {
        configDef: deviceConfigDef.MaxHeatingThermostat,
        createCallback: (config, lastState) -> new MaxHeatingThermostat(config, lastState)
      })

      @framework.deviceManager.registerDeviceClass("MaxWallThermostat", {
        configDef: deviceConfigDef.MaxWallThermostat,
        createCallback: (config, lastState) -> new MaxWallThermostat(config, lastState)
      })

      @framework.deviceManager.registerDeviceClass("MaxContactSensor", {
        configDef: deviceConfigDef.MaxContactSensor,
        createCallback: (config, lastState) -> new MaxContactSensor(config, lastState)
      })

      @framework.deviceManager.registerDeviceClass("MaxCube", {
        configDef: deviceConfigDef.MaxCube,
        createCallback: (config, lastState) -> new MaxCube(config, lastState)
      })

    isWindowOpen: (rfAddress) ->
      @_lastAction = settled(@_lastAction).then( =>
        device = @mc.devices[rfAddress]
        unless device?
          return null
        return !@mc.allWindowsClosed(device.roomId)
      )
      return @_lastAction

    setTemperatureSetpoint: (rfAddress, mode, value) ->
      @_lastAction = settled(@_lastAction).then( => 
        @mc.setTemperatureAsync(rfAddress, mode, value) 
      )
      return @_lastAction


  plugin = new MaxThermostat
 
  class MaxHeatingThermostat extends env.devices.HeatingThermostat

    constructor: (@config, lastState) ->
      @id = @config.id
      @name = @config.name
      @_temperatureSetpoint = lastState?.temperatureSetpoint?.value
      @_mode = lastState?.mode?.value or "auto"
      @_battery = lastState?.battery?.value or "ok"
      @_lastSendTime = 0

      plugin.mc.on("update", (data) =>
        data = data[@config.rfAddress]
        if data?
          now = new Date().getTime()
          unless @_tempToSetIfWindowClosed?
            ###
            Give the cube some time to handle the changes. If we send new values to the cube
            we set _lastSendTime to the current time. We consider the values as succesfull set, when
            the command was not rejected. But the updates comming from the cube in the next 30
            seconds do not always reflect the updated values, therefore we ignoring the old values
            we got by the update message for 30 seconds. 

            In the case that the cube did not react to our the send commands, the values will be 
            overwritten with the internal state (old ones) of the cube after 30 seconds, because
            the update event is emitted by max-control periodically.
            ###
            if now - @_lastSendTime < 30*1000
              # only if values match, we are synced
              if data.setpoint is @_temperatureSetpoint and data.mode is @_mode
                @_setSynced(true)
            else
              # more then 30 seconds passed, set the values anyway
              @_setSetpoint(data.setpoint)
              @_setMode(data.mode)
              @_setSynced(true)
          else
            plugin.isWindowOpen(@config.rfAddress).then( (windowOpen) =>
              if windowOpen
                @_setSetpoint(data.setpoint)
                @_setMode(data.mode)
              else
                if plugin.config.debug
                  env.logger.debug("All windows closed, setting saved temperature")
                tempToSet = @_tempToSetIfWindowClosed
                @_tempToSetIfWindowClosed = undefined
                return plugin.setTemperatureSetpoint(
                  @config.rfAddress, @_mode, tempToSet
                ).then( () =>
                  @_lastSendTime = new Date().getTime()
                  @_setSynced(false)
                  @_setSetpoint(tempToSet)
                )
            ).catch( (err) =>
              env.logger.error("Error setting temp after window was closed: #{err.message}")
              env.logger.debug(err)
            )
          @_setValve(data.valve)
          @_setBattery(data.battery)
        return
      )
      super()

    changeModeTo: (mode) ->
      temp = @_temperatureSetpoint
      if mode is "auto"
        temp = null
      return plugin.setTemperatureSetpoint(@config.rfAddress, mode, temp).then( =>
        @_lastSendTime = new Date().getTime()
        @_setSynced(false)
        @_setMode(mode)
      )

    changeTemperatureTo: (temperatureSetpoint) ->
      if @temperatureSetpoint is temperatureSetpoint then return
      return plugin.isWindowOpen(@config.rfAddress).then( (windowOpen) => 
        if windowOpen
          env.logger.debug("A window is open waiting till window is closed") if plugin.config.debug
          @_setSynced(false)
          @_tempToSetIfWindowClosed = temperatureSetpoint
          @_lastSendTime = new Date().getTime()
          return
        else
          return plugin.setTemperatureSetpoint(
            @config.rfAddress, @_mode, temperatureSetpoint
          ).then( =>
            @_lastSendTime = new Date().getTime()
            @_setSynced(false)
            @_setSetpoint(temperatureSetpoint)
          )
      )


  class MaxWallThermostat extends env.devices.TemperatureSensor
    _temperature: null

    constructor: (@config, lastState) ->
      @id = @config.id
      @name = @config.name
      @_temperature = lastState?.temperature?.value
      super()
      
      plugin.mc.on("update", (data) =>
        data = data[@config.rfAddress]
        if data?.actualTemperature?
          @_temperature = data.actualTemperature
          @emit 'temperature', @_temperature
      )

    getTemperature: -> Promise.resolve(@_temperature)

  class MaxContactSensor extends env.devices.ContactSensor

    constructor: (@config, lastState) ->
      @id = @config.id
      @name = @config.name
      @_contact = lastState?.contact?.value

      plugin.mc.on("update", (data) =>
        data = data[@config.rfAddress]
        if data?
          @_setContact(data.state is 'closed')
        return
      )
      super()

  class MaxCube extends env.devices.Sensor

    attributes:
      dutycycle:
        description: "Percentage of max rf limit reached"
        type: "number"
        unit: "%"
      memoryslots:
        description: "Available memory slots for commands"
        type: "number"

    _dutycycle: 0
    _memoryslots: 50

    constructor: (@config, lastState) ->
      @id = @config.id
      @name = @config.name
      @_dutycycle = plugin.mc.dutyCycle
      @_memoryslots = plugin.mc.memorySlots

      plugin.mc.on("status", (info) =>
        @emit 'dutycycle', info.dutyCycle
        @emit 'memoryslots', info.memorySlots
      )
      super()

    getDutycycle: -> Promise.resolve(@_dutycycle)
    getMemoryslots: -> Promise.resolve(@_memoryslots)

  return plugin
