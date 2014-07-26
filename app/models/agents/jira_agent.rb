#!/usr/bin/env ruby

require 'cgi'
require 'httparty'
require 'date'

module Agents
  class JiraAgent < Agent
    cannot_receive_events!

    description <<-MD
      The Jira Agent subscribes to Jira issue updates.

      `jira_url` specifies the full URL of the jira installation, including https://
      `jql` is an optional Jira Query Language-based filter to limit the flow of events. See [JQL Docs](https://confluence.atlassian.com/display/JIRA/Advanced+Searching) for details. 
      `username` and `password` are optional, and may need to be specified if your Jira instance is read-protected
      `timeout` is an optional parameter that specifies how long the request processing may take in minutes.

      The agent does periodic queries and emits the events containing the updated issues in JSON format.
      NOTE: upon the first execution, the agent will fetch everything available by the JQL query. So if it's not desirable, limit the `jql` query by date.
    MD

    event_description <<-MD
      Events are the raw JSON generated by Jira REST API

      {
        "expand": "editmeta,renderedFields,transitions,changelog,operations",
        "id": "80127",
        "self": "https://jira.atlassian.com/rest/api/2/issue/80127",
        "key": "BAM-3512",
        "fields": {
          ...
        }
      }
    MD

    default_schedule "every_10m"
    MAX_EMPTY_REQUESTS = 10

    def default_options
      {
        'username'  => '',
        'password' => '',
        'jira_url' => 'https://jira.atlassian.com',
        'jql' => '',
        'expected_update_period_in_days' => '7',
        'timeout' => '1'
      }
    end

    def validate_options
      errors.add(:base, "you need to specify password if user name is set") if options['username'].present? and not options['password'].present?
      errors.add(:base, "you need to specify your jira URL") unless options['jira_url'].present?
      errors.add(:base, "you need to specify the expected update period") unless options['expected_update_period_in_days'].present?
      errors.add(:base, "you need to specify request timeout") unless options['timeout'].present?
    end

    def working?
      event_created_within?(interpolated['expected_update_period_in_days']) && !recent_error_logs?
    end

    def check
      last_run = nil

      current_run = Time.now.utc.iso8601
      last_run = Time.parse(memory[:last_run]) if memory[:last_run]
      issues = get_issues(last_run)

      issues.each do |issue|
        updated = Time.parse(issue['fields']['updated'])

        # this check is more precise than in get_issues()
        # see get_issues() for explanation
        if not last_run or updated > last_run
          create_event :payload => issue
        end
      end

      memory[:last_run] = current_run
    end

  private
    def request_url(jql, start_at)
      "#{interpolated[:jira_url]}/rest/api/2/search?jql=#{CGI::escape(jql)}&fields=*all&startAt=#{start_at}"
    end

    def request_options
      ropts = {:headers => {"User-Agent" => "Huginn (https://github.com/cantino/huginn)"}}

      if !interpolated[:username].empty?
        ropts = ropts.merge({:basic_auth => {:username =>interpolated[:username], :password=>interpolated[:password]}})
      end

      ropts
    end

    def get(url, options)
        response = HTTParty.get(url, options)

        if response.code == 400
          raise RuntimeError.new("Jira error: #{response['errorMessages']}") 
        elsif response.code == 403
          raise RuntimeError.new("Authentication failed: Forbidden (403)")
        elsif response.code != 200
          raise RuntimeError.new("Request failed: #{response}")
        end

        response
    end

    def get_issues(since)
      startAt = 0
      issues = []

      # JQL doesn't have an ability to specify timezones
      # Because of this we have to fetch issues 24 h
      # earlier and filter out unnecessary ones at a later
      # stage. Fortunately, the 'updated' field has GMT
      # offset
      since -= 24*60*60 if since

      jql = ""

      if !interpolated[:jql].empty? && since
        jql = "(#{interpolated[:jql]}) and updated >= '#{since.strftime('%Y-%m-%d %H:%M')}'"
      else
        jql = interpolated[:jql] if !interpolated[:jql].empty?
        jql = "updated >= '#{since.strftime('%Y-%m-%d %H:%M')}'" if since
      end

      start_time = Time.now

      request_limit = 0
      loop do
        response = get(request_url(jql, startAt), request_options)

        if response['issues'].length == 0
          request_limit+=1
        end

        if request_limit > MAX_EMPTY_REQUESTS
          raise RuntimeError.new("There is no progress while fetching issues")
        end

        if Time.now > start_time + interpolated['timeout'].to_i * 60
          raise RuntimeError.new("Timeout exceeded while fetching issues")
        end

        issues += response['issues']
        startAt += response['issues'].length
 
        break if startAt >= response['total']
      end

      issues
    end

  end
end
