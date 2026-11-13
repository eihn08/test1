# encoding: utf-8
# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'securerandom'
require 'time'

module ThienMinh
  class Store
    attr_reader :data_dir

    def initialize(data_dir)
      @data_dir = data_dir
      @mutex = Mutex.new
      @db_path = File.join(@data_dir, 'db.json')
      FileUtils.mkdir_p(@data_dir)
      ensure_db!
    end

    def catalog
      read_json('catalog.json')
    end

    def capacity_schedule
      read_json('capacity_schedule.json')
    end

    def policies
      read_json('policies.json')
    end

    def sample_rfps
      read_json('sample_rfps.json')
    end

    def update_catalog(new_data)
      write_json('catalog.json', new_data)
    end

    def update_policies(new_data)
      write_json('policies.json', new_data)
    end

    def update_capacity_schedule(new_data)
      write_json('capacity_schedule.json', new_data)
    end

    def all_cases
      @mutex.synchronize do
        db = read_db
        (db['cases'] || []).sort_by { |c| c['updated_at'] || '' }.reverse
      end
    end

    def find_case(id)
      @mutex.synchronize do
        db = read_db
        (db['cases'] || []).find { |c| c['id'] == id }
      end
    end

    def save_case(case_record)
      @mutex.synchronize do
        db = read_db
        db['cases'] ||= []
        idx = db['cases'].index { |c| c['id'] == case_record['id'] }
        now = Time.now.iso8601
        case_record['created_at'] ||= now
        case_record['updated_at'] = now
        if idx
          db['cases'][idx] = case_record
        else
          db['cases'] << case_record
        end
        write_db(db)
        case_record
      end
    end

    def delete_case(id)
      @mutex.synchronize do
        db = read_db
        db['cases'] ||= []
        before = db['cases'].size
        db['cases'].reject! { |c| c['id'] == id }
        write_db(db)
        before != db['cases'].size
      end
    end

    def settings
      @mutex.synchronize do
        db = read_db
        default_settings.merge(db['settings'] || {})
      end
    end

    def update_settings(patch)
      @mutex.synchronize do
        db = read_db
        current = default_settings.merge(db['settings'] || {})
        patch.each do |k, v|
          next if v.nil?
          current[k.to_s] = v
        end
        db['settings'] = current
        write_db(db)
        current
      end
    end

    def reset_demo!
      @mutex.synchronize do
        db = {
          'settings' => (read_db['settings'] || default_settings),
          'cases' => [],
          'seeded' => false
        }
        write_db(db)
      end
    end

    def seeded?
      @mutex.synchronize do
        !!read_db['seeded']
      end
    end

    def mark_seeded!
      @mutex.synchronize do
        db = read_db
        db['seeded'] = true
        write_db(db)
      end
    end

    private

    def default_settings
      {
        'engine_mode' => 'hybrid',
        'provider' => 'gemini',
        'model' => 'gemini-2.5-flash',
        'api_key' => '',
        'temperature' => 0.2
      }
    end

    def ensure_db!
      return if File.exist?(@db_path)

      initial = {
        'settings' => default_settings,
        'cases' => [],
        'seeded' => false
      }
      write_db(initial)
    end

    def read_db
      JSON.parse(File.read(@db_path, encoding: 'UTF-8'))
    rescue StandardError
      { 'settings' => default_settings, 'cases' => [], 'seeded' => false }
    end

    def write_db(data)
      File.write(@db_path, JSON.pretty_generate(data), encoding: 'UTF-8')
    end

    def read_json(filename)
      path = File.join(@data_dir, filename)
      JSON.parse(File.read(path, encoding: 'UTF-8'))
    end

    def write_json(filename, data)
      path = File.join(@data_dir, filename)
      File.write(path, JSON.pretty_generate(data), encoding: 'UTF-8')
    end
  end
end

