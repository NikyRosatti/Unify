# frozen_string_literal: true

require 'sinatra'
require 'sinatra/activerecord'
require 'sinatra/base'
require 'sinatra/cors'
require 'sinatra/json'
require 'byebug'
require 'fileutils'
require 'dotenv/load'
require 'pdf-reader'
require 'json'
require 'openai'
require 'digest'

require_relative '../models/document'
require_relative '../models/question'

require_relative '../../helpers'

# Practice controller
# It handles the practice views
class PracticeController < Sinatra::Base
  helpers DocumentService
  helpers PracticeService
  helpers UserService
  helpers UtilsService
  enable :sessions

  before do
    session[:is_an_user_present] = session[:is_an_user_present] || false
    @is_an_user_present = session[:is_an_user_present] || false
  end

  get '/practice' do
    authenticate_user!
    erb :practice
  end

  post '/practice' do
    # logger.info 'Received request to generate quiz'
    # logger.info "Params: #{params.inspect}"

    file = fetch_file(params)
    return file unless file.is_a?(Tempfile)

    response_save_pdf = save_pdf(params)
    document = response_save_pdf[2] # Rescato el documento de la base de datos para pasarla al metodo

    redirect "/documents/#{document.id}/practice_doc" if response_save_pdf[0] == 201 # Ya existe en la base de datos

    return json_error(response_save_pdf[1], response_save_pdf[0]) unless response_save_pdf[0] == 202

    full_text = extract_text_from_pdf(file)
    return json_error('Failed to extract text from PDF', 500) if full_text.empty?

    @questions = generate_questions(full_text)
    return json_error('Failed to generate quiz', 503) unless @questions

    puts '<!-- Starting Saving Questions -->'
    save_questions_to_db(@questions, document)
    @document = document
    puts '<!-- End Saving Questions -->'

    status 251 # Llegar de manera adecuada y mostrar el cuestionario
    logger.info 'Correcta verificacion de metodos'
    session[:document_id] = @document.id
    puts "Document ID: #{session[:document_id]}"

    session[:current_question_index] = 0 # Iniciamos en la primera pregunta
    session[:answered_questions] = [] # Inicializamos el array para las respuestas

    @current_question = Question.where(document: session[:document_id]).first # Mostramos la primera pregunta

    erb :question
  end

  post '/next_question' do
    document_id = session[:document_id]
    current_question_index = session[:current_question_index]

    # Guarda las preguntas correspondientes al documento almacenado en la base de datos
    questions = Question.where(document_id: document_id).order(:id)

    if questions.nil? || current_question_index.nil?
      @error = 'No se encontraron preguntas o índice. Por favor, sube un PDF para generar el quiz.'
      redirect '/practice'
    end

    selected_answer = params[:selected_option]
    @current_question = questions.offset(current_question_index).first # Obtiene la pregunta actual

    process_answer(selected_answer)

    session[:current_question_index] += 1 # Avanza al siguiente índice
    logger.debug "Current question index: #{session[:current_question_index]}"

    @progress = (session[:current_question_index].to_f / questions.size * 100).to_i # Calculamos el porcentaje

    if session[:current_question_index] < questions.size
      @current_question = questions.offset(session[:current_question_index]).first  # Obtiene la siguiente pregunta
      body @current_question
      erb :question
    else
      complete_quiz(questions)
    end
  end

  get '/documents/:id/practice_doc' do
    authenticate_user!
    document_id = params[:id] # El ID del documento que el usuario selecciona
    @document = Document.find(document_id)

    if @document.nil?
      @error = 'No hay preguntas disponibles para este documento.'
      redirect '/'
    end

    session[:document_id] = document_id
    session[:current_question_index] = 0 # Iniciar en la primera pregunta
    session[:answered_questions] = [] # Inicializar respuestas contestadas

    @current_question = Question.where(document: session[:document_id]).first # Mostramos la primera pregunta

    if @current_question.nil?
      @error = 'No se encontraron preguntas para este documento.'
      redirect '/'
    else
      erb :question
    end
  end
end
