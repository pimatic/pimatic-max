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
        @mc.once("connected", resolve)
        @mc.once('error', reject)
        return
      ).timeout(60000).catch( (error) ->
        env.logger.error "Error on connecting to max cube: #{error.message}"
        env.logger.debug error.stack
        return
      )

      @mc.on('response', (res) =>
        env.logger.debug "Response: ", res
      )

      @mc.on("update", (data) =>
        env.logger.debug "got update", data
      )

      @mc.on('error', (error) =>
        env.logger.error "connection error: #{error}"
        env.logger.debug error.stack
      )

      deviceConfigDef = require("./device-config-schema")
      @framework.deviceManager.registerDeviceClass("MaxThermostatDevice", {
        configDef: deviceConfigDef.MaxThermostatDevice,
        createCallback: (config) -> new MaxThermostatDevice(config)
      })

      @framework.deviceManager.registerDeviceClass("MaxContactSensor", {
        configDef: deviceConfigDef.MaxContactSensor,
        createCallback: (config) -> new MaxContactSensor(config)
      })

      @framework.deviceManager.registerDeviceClass("MaxCube", {
        configDef: deviceConfigDef.MaxCube,
        createCallback: (config, lastState) -> new MaxCube(config, lastState)
      })
      # wait till all plugins are loaded
      @framework.on "after init", =>
        # Check if the mobile-frontent was loaded and get a instance
        mobileFrontend = @framework.pluginManager.getPlugin 'mobile-frontend'
        if mobileFrontend?
          mobileFrontend.registerAssetFile 'js', "pimatic-max-thermostat/app/jqm-spinbox.js"
          mobileFrontend.registerAssetFile 'js', "pimatic-max-thermostat/app/js.coffee"
          mobileFrontend.registerAssetFile 'css', "pimatic-max-thermostat/app/css/css.css"
          mobileFrontend.registerAssetFile 'html', "pimatic-max-thermostat/app/template.html"
        else
          env.logger.warn(
            "MaxThermostat could not find the mobile-frontend. No gui will be available"
          )

      @framework.ruleManager.addActionProvider(new MaxModeActionProvider(@framework))
      @framework.ruleManager.addActionProvider(new MaxTempActionProvider(@framework))

    setTemperature: (deviceNo, mode, value) ->
      @_lastAction = settled(@_lastAction).then( => 
        @mc.setTemperatureAsync(deviceNo, mode, value) 
      )
      return @_lastAction


  plugin = new MaxThermostat
 
  class MaxThermostatDevice extends env.devices.Device

    attributes:
      settemperature:
        description: "the temp that should be set"
        type: "number"
        unit: "°C"
      mode:
        description: "the current mode"
        type: "string"
        enum: ["auto", "manu", "boost"]

    actions:
      changeModeTo:
        params: 
          mode: 
            type: "string"
      changeTemperatureTo:
        params: 
          settemperature: 
            type: "number"

    template: "MaxThermostatDevice"

    _mode: "auto"
    _settemperature: null

    constructor: (@config) ->
      @id = @config.id
      @name = @config.name
      @_settemperature = @config.actTemp
      @_mode = @config.mode

      plugin.mc.on("update", (data) =>
        data = data[@config.deviceNo]
        if data?
          @config.actTemp = data.setpoint
          @config.mode = data.mode
          # @config.comfyTemp = data.comfortTemperature // Doesn't make sense
          # @config.ecoTemp = data.ecoTemperature // you'll define these in the pimatic config
          @config.battery = data.battery
          @_setTemp(@config.actTemp)
          @_setMode(@config.mode)
        return
      )
      super()

    getMode: () -> Promise.resolve(@_mode)
    getSettemperature: () -> Promise.resolve(@_settemperature)

    _setMode: (mode) ->
      if mode is @_mode then return
      @_mode = mode
      @emit "mode", @_mode

    _setTemp: (settemperature) ->
      if settemperature is @_settemperature then return
      @_settemperature = settemperature
      @emit "settemperature", @_settemperature

    changeModeTo: (mode) ->
      temp = @_settemperature
      if mode is "auto"
        temp = null
      return plugin.setTemperature(@config.deviceNo, mode, temp).then( =>
        @_setMode(mode)
      )
        
    changeTemperatureTo: (temperature) ->
      if @settemperature is temperature then return
      return plugin.setTemperature(@config.deviceNo, @_mode, temperature)

  class MaxContactSensor extends env.devices.ContactSensor

    constructor: (@config) ->
      @id = @config.id
      @name = @config.name

      plugin.mc.on("update", (data) =>
        data = data[@config.deviceNo]
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

  class MaxModeActionProvider extends env.actions.ActionProvider

    constructor: (@framework) ->

    # ### parseAction()
    ###
    Parses the above actions.
    ###
    parseAction: (input, context) =>
      # The result the function will return:
      retVar = null

      thermostats = _(@framework.deviceManager.devices).values().filter( 
        (device) => device.hasAction("changeModeTo") 
      ).value()

      if thermostats.length is 0 then return

      device = null
      valueTokens = null
      match = null

      # Try to match the input string with:
      M(input, context)
        .match('set mode of ')
        .matchDevice(thermostats, (next, d) =>
          next.match(' to ')
            .matchStringWithVars( (next, ts) =>
              m = next.match(' mode', optional: yes)
              if device? and device.id isnt d.id
                context?.addError(""""#{input.trim()}" is ambiguous.""")
                return
              device = d
              valueTokens = ts
              match = m.getFullMatch()
            )
        )

      if match?
        if valueTokens.length is 1 and not isNaN(valueTokens[0])
          value = valueTokens[0] 
          assert(not isNaN(value))
          modes = ["eco", "boost", "auto", "manu", "comfy"] 
          # TODO: Implement eco & comfy in changeModeTo method!
          if modes.indexOf(value) < -1
            context?.addError("Allowed modes: eco,boost,auto,manu,comfy")
            return
        return {
          token: match
          nextInput: input.substring(match.length)
          actionHandler: new MaxModeActionHandler(@framework, device, valueTokens)
        }
      else 
        return null


  class MaxModeActionHandler extends env.actions.ActionHandler

    constructor: (@framework, @device, @valueTokens) ->
      assert @device?
      assert @valueTokens?

    ###
    Handles the above actions.
    ###
    _doExecuteAction: (simulate, value) =>
      return (
        if simulate
          __("would set mode %s to %s%%", @device.name, value)
        else
          @device.changeModeTo(value).then( => __("set mode %s to %s%%", @device.name, value) )
      )

    # ### executeAction()
    executeAction: (simulate) => 
      @framework.variableManager.evaluateStringExpression(@valueTokens).then( (value) =>
        @lastValue = value
        return @_doExecuteAction(simulate, value)
      )

    # ### hasRestoreAction()
    hasRestoreAction: -> yes
    # ### executeRestoreAction()
    executeRestoreAction: (simulate) => Promise.resolve(@_doExecuteAction(simulate, @lastValue))



  class MaxTempActionProvider extends env.actions.ActionProvider

    constructor: (@framework) ->

    # ### parseAction()
    ###
    Parses the above actions.
    ###
    parseAction: (input, context) =>
      # The result the function will return:
      retVar = null

      thermostats = _(@framework.deviceManager.devices).values().filter( 
        (device) => device.hasAction("changeTemperatureTo") 
      ).value()

      if thermostats.length is 0 then return

      device = null
      valueTokens = null
      match = null

      # Try to match the input string with:
      M(input, context)
        .match('set temp of ')
        .matchDevice(thermostats, (next, d) =>
          next.match(' to ')
            .matchNumericExpression( (next, ts) =>
              m = next.match('°C', optional: yes)
              if device? and device.id isnt d.id
                context?.addError(""""#{input.trim()}" is ambiguous.""")
                return
              device = d
              valueTokens = ts
              match = m.getFullMatch()
            )
        )

      if match?
        if valueTokens.length is 1 and not isNaN(valueTokens[0])
          value = valueTokens[0] 
          assert(not isNaN(value))
          value = parseFloat(value)
          if value < 0.0
            context?.addError("Can't set temp to a negativ value.")
            return
          if value > 32.0
            context?.addError("Can't set temp higher than 32°C.")
            return
        return {
          token: match
          nextInput: input.substring(match.length)
          actionHandler: new MaxTempActionHandler(@framework, device, valueTokens)
        }
      else 
        return null

  class MaxTempActionHandler extends env.actions.ActionHandler

    constructor: (@framework, @device, @valueTokens) ->
      assert @device?
      assert @valueTokens?

    # _clampVal: (value) ->
    #   assert(not isNaN(value))
    #   return (switch
    #     when value > 32 then 32
    #     when value < 0 then 0
    #     else value
    #   )

    ###
    Handles the above actions.
    ###
    _doExecuteAction: (simulate, value) =>
      return (
        if simulate
          __("would set temp of %s to %s°C", @device.name, value)
        else
          @device.changeTemperatureTo(value).then( => 
            __("set temp of %s to %s°C", @device.name, value) 
          )
      )

    # ### executeAction()
    executeAction: (simulate) => 
      @framework.variableManager.evaluateNumericExpression(@valueTokens).then( (value) =>
        # value = @_clampVal value
        @lastValue = value
        return @_doExecuteAction(simulate, value)
      )

    # ### hasRestoreAction()
    hasRestoreAction: -> yes
    # ### executeRestoreAction()
    executeRestoreAction: (simulate) => Promise.resolve(@_doExecuteAction(simulate, @lastValue))

  return plugin
