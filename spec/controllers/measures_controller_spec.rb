require 'rails_helper'
require 'fileutils'
require 'nokogiri'

RSpec.describe API::V1::MeasuresController, type: 'controller' do
  include RSpec::Matchers

  before(:each) do
    @request.env['devise.mapping'] = Devise.mappings[:user]
    @request.headers['Accept'] = 'application/vnd.api+json'
    @request.headers['Content-Type'] = 'application/vnd.api+json'
    user = create(:user)
    sign_in user
    setup_fixture_data
  end

  it 'show all' do
    get :index, reporting_period: 2015, tags: 'Continuous'
    expect(response).to have_http_status(:success)
    executions = JSON.parse(response.body)
    assert executions.any?
  end

  it 'get measure' do
    Measure.all.each do |measure|
      @cms_id = measure.cms_id
      break unless @cms_id.nil?
    end
    get :show, id: @cms_id
    expect(response).to have_http_status(:success)
    assert_equal @cms_id, JSON.parse(response.body)['measures']['id']
  end
end
