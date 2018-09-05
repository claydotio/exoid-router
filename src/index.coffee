_ = require 'lodash'
log = require 'loga'
Joi = require 'joi'
Promise = require 'bluebird'

thrower = ({status, info, ignoreLog}) ->
  status ?= 400

  error = new Error info
  Error.captureStackTrace error, thrower

  error.status = status
  error.info = info
  error.ignoreLog = ignoreLog
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

BATCH_CHUNK_TIMEOUT_MS = 30
BATCH_CHUNK_TIMEOUT_BACKOFF_MS = 50
MAX_BATCH_CHUNK_TIMEOUT_MS = 15000

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
    return new Promise (resolve) =>
      handler = @state.paths[path]

      unless handler
        @throw {status: 400, info: "Handler not found for path: #{path}"}

      resolve handler body, req, io
    .then (result) ->
      {result, error: null}
    .catch (error) ->
      unless error.ignoreLog
        log.error error
      errObj = if error._exoid
        {status: error.status, info: error.info}
      else
        {status: 500}

      {result: null, error: errObj}

  setMiddleware: (@middlewareFn) => null

  setDisconnect: (@disconnectFn) => null

  onConnection: (socket) =>
    socket.on 'disconnect', =>
      @disconnectFn? socket

    socket.on 'exoid', (body) =>
      requests = body?.requests
      isComplete = false

      emitBatchChunk = (responses) ->
        socket.emit body.batchId, responses

      responseChunk = {}
      timeoutMs = BATCH_CHUNK_TIMEOUT_MS
      emitBatchChunkFn = ->
        timeoutMs += BATCH_CHUNK_TIMEOUT_BACKOFF_MS
        unless _.isEmpty responseChunk
          emitBatchChunk responseChunk
          responseChunk = {}
        if timeoutMs < MAX_BATCH_CHUNK_TIMEOUT_MS and not isComplete
          setTimeout emitBatchChunkFn, timeoutMs

      setTimeout emitBatchChunkFn, timeoutMs

      @middlewareFn body, socket.request
      .then (req) =>

        try
          @assert requests, Joi.array().items Joi.object().keys
            path: Joi.string()
            body: Joi.any().optional()
            streamId: Joi.string().optional()
        catch error
          isComplete = true
          responseChunk = {
            isError: true
            status: error.status
            info: error.info
          }

        Promise.map requests, (request) =>
          emitRequest = (response) ->
            socket.emit request.streamId, response
          @resolve request.path, request.body, socket.request, {
            emit: emitRequest
            route: request.path
            socket: socket
          }
          .then (response) ->
            responseChunk[request.streamId] = response
          .catch (err) ->
            console.log 'caught exoid error', err
        .then ->
          isComplete = true

      .catch (err) ->
        console.log err

module.exports = new ExoidRouter()
