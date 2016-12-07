_ = require 'lodash'
log = require 'loga'
Joi = require 'joi'
Promise = require 'bluebird'

thrower = ({status, info}) ->
  status ?= 400

  error = new Error info
  Error.captureStackTrace error, thrower

  error.status = status
  error.info = info
  error._exoid = true

  throw error

assert = (obj, schema) ->
  valid = Joi.validate obj, schema, {presence: 'required', convert: false}

  if valid.error
    try
      thrower info: valid.error.message
    catch error
      Error.captureStackTrace error, assert
      throw error

class ExoidRouter
  constructor: (@state = {}) -> null

  throw: thrower
  assert: assert

  bind: (transform) =>
    new ExoidRouter transform @state

  on: (path, handler) =>
    @bind (state) ->
      _.defaultsDeep {
        paths: {"#{path}": handler}
      }, state

  resolve: (path, body, req, io) =>
    cache = []
    return new Promise (resolve) =>
      handler = @state.paths[path]

      unless handler
        @throw {status: 400, info: "Handler not found for path: #{path}"}

      resolve handler body, _.defaults({
        cache: (id, resource) ->
          if _.isPlainObject id
            resource = id
            id = id.id
          cache.push {path: id, result: resource}
      }, req), io
    .then (result) ->
      {result, cache, error: null}
    .catch (error) ->
      log.error error
      errObj = if error._exoid
        {status: error.status, info: error.info}
      else
        {status: 500}

      {result: null, error: errObj, cache: cache}

  setMiddleware: (@middlewareFn) => null

  setDisconnect: (@disconnectFn) => null

  onConnection: (socket) =>
    socket.on 'disconnect', =>
      @disconnectFn? socket

    socket.on 'exoid', (body) =>
      requests = body?.requests
      cache = []

      emitBatch = (response) ->
        socket.emit body.batchId, response

      @middlewareFn body, socket.request
      .then (req) =>

        try
          @assert requests, Joi.array().items Joi.object().keys
            path: Joi.string()
            body: Joi.any().optional()
            streamId: Joi.string().optional()
        catch error
          return emitBatch {
            isError: true
            status: error.status
            info: error.info
          }

        Promise.all _.map requests, (request) =>
          emitRequest = (response) ->
            socket.emit request.streamId, response
          @resolve request.path, request.body, socket.request, {
            emit: emitRequest
            route: request.path
            socket: socket
          }
        .then (settled) ->
          {
            results: _.map settled, ({result}) -> result
            errors: _.map settled, ({error}) -> error
            cache: _.reduce settled, (cache, result) ->
              cache.concat result.cache
            , []
          }
      .then (response) -> emitBatch response
      .catch (err) ->
        console.log err

module.exports = new ExoidRouter()
