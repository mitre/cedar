# Test executions are the main object in Cedar, set up by the user to
# drive the generation of specific QRDA documents
class TestExecution
  include Mongoid::Document
  include Mongoid::Timestamps::Created
  include Mongoid::Timestamps::Updated
  include GlobalID::Identification

  field :state,               type: Symbol,  default: :incomplete  # incomplete, passed, failed
  field :step,                type: Symbol,  default: :details     # see StepsController
  field :wizard_progress,     type: Float,   default: 0            # 0 to 100
  field :qrda_progress,       type: Float,   default: 0            # 0 to 100
  field :name,                type: String,  default: ''
  field :description,         type: String,  default: ''
  field :reporting_period,    type: String,  default: ''
  field :qrda_type,           type: String,  default: nil          # 1 or 3
  field :results,             type: Hash,    default: { passed: 0, total: 0 }
  field :disable_details,     type: Boolean, default: false
  field :file_path,           type: String,  default: ''

  has_and_belongs_to_many :measures
  has_and_belongs_to_many :validations
  has_many                :documents,
                          inverse_of: :test_execution,
                          dependent: :destroy,
                          order: 'name ASC'
  belongs_to              :user

  accepts_nested_attributes_for :documents

  scope :order_by_date, -> { order_by(created_at: :desc) }
  scope :order_by_name, -> { order_by(name: :asc) }
  scope :order_by_state, -> { order_by(state: :asc) }
  scope :state, -> (state) { where state: state }
  scope :user, -> (user) { where user_id: user }

  # When we've gathered enough information, create the QRDA document package
  # First, disable all of the detail fields so dupe documents cannot be created
  # Then, generate a new document for each validation and a few acceptable docs
  # When all documents are created, zip them up and serve them to the file system
  # Finally, clean up any unnecessary patient records generated by the process
  def create_documents
    if qrda_progress == 0
      self.disable_details = true
      @documents_to_generate = validation_ids.count + 2
      @current_document = 1
      generate_invalid_qrda_text
      generate_valid_qrda_text
      zip_qrda_files
      HealthDataStandards::CQM::PatientCache.where('value.test_id'.to_sym.ne => nil).destroy_all
      HealthDataStandards::CQM::QueryCache.where('value.test_id'.to_sym.exists => true).destroy_all
    end
  end

  # Find the bundle that corresponds to the reporting_period
  def bundle
    HealthDataStandards::CQM::Bundle.find_by measure_period_start: BUNDLE_MAP[reporting_period]
  end

  # Assume that the test_execution passed, loop through all of its documents,
  # and fail it if the expected and actual results don't match
  def set_overview_state
    pass_test = true
    passed_validations = 0
    total_validations = 0
    document_ids.each do |document|
      doc = Document.find(document)
      total_validations += 1
      doc_pass = doc.update_state
      pass_test &&= doc_pass
      passed_validations += 1 if doc_pass
    end
    pass_test ? update_attribute(:state, :passed) : update_attribute(:state, :failed)
    update_attribute(:results, passed: passed_validations, total: total_validations)
  end

  # Allow for test_execution copying without associated qrda documents
  def dup_test
    duplicate = dup
    duplicate.update_attributes(
      state: :incomplete,
      step: :details,
      wizard_progress: 0,
      qrda_progress: 0,
      results: { passed: 0, total: 0 },
      disable_details: false,
      file_path: ''
    )
    duplicate.save
    duplicate
  end

  private

  # For each chosen validation, generate one or two invalid qrda documents
  def generate_invalid_qrda_text
    validation_ids.each do |validation_id|
      Random.new.rand(1..2).times do
        measure_id = determine_useful_measures(validation_id).sample
        measure = HealthDataStandards::CQM::Measure.find_by(_id: measure_id)
        doc = Document.create(
          name: HOSPITALS.sample,
          validation_id: validation_id,
          test_execution: self,
          measure_id: measure.hqmf_id,
          qrda: generate_qrda_text(measure)
        )
        Cedar::Invalidator.invalidate_qrda(doc)
      end
      update_qrda_progress
    end
  end

  # To prevent teaching to the test, generate some totally valid qrda documents
  def generate_valid_qrda_text
    Random.new.rand(1..4).times do
      measure = HealthDataStandards::CQM::Measure.find_by(_id: measure_ids.sample)
      Document.create(
        name: HOSPITALS.sample,
        expected_result: :accept,
        test_execution: self,
        measure_id: measure.hqmf_id,
        qrda: generate_qrda_text(measure)
      )
    end
    update_qrda_progress
  end

  # Use a random measure ID from the test_execution list of measure ids
  # Take the one bundle object from the db
  # Array of patient record objects found from the patient cache for the particular measure
  def generate_qrda_text(measure)
    measure_id = measure['hqmf_id']
    start_date = DateTime.new(reporting_period.to_i, 1, 1).utc
    end_date = start_date.years_since(1) - 1
    bundle = self.bundle
    patient_records = HealthDataStandards::CQM::PatientCache.where('value.measure_id' => measure_id, 'value.test_id' => nil).to_a.map(&:record)
    if qrda_type == '3' # TODO: We could potentially create a Cat 3 file without creating Cat 1 files
      zip = Cypress::CreateDownloadZip.create_zip(patient_records, 'qrda', measure, start_date, end_date)
      c3c = Cypress::Cat3Calculator.new([measure_id], bundle)
      c3c.import_cat1_zip(zip)
      c3c.generate_cat3(start_date, end_date)
    elsif qrda_type == '1'
      formatter = Cypress::QRDAExporter.new([measure], start_date, end_date)
      patient = patient_records.sample
      Cypress::DemographicsRandomizer.randomize(patient)
      formatter.export(patient)
    else
      raise 'Unknown QRDA type'
    end
  end

  # Zip all the qrda files associated with a given test execution
  # While doing so, randomly order and index them
  def zip_qrda_files
    file_name = name.gsub(/[^0-9A-Za-z]/, '_')
    FileUtils.mkdir_p("public/data/#{user_id}")
    update_attribute(:file_path, "data/#{user_id}/#{file_name}.zip")
    Zip::ZipOutputStream.open('public/' + file_path) do |zip|
      i = 0
      document_ids.shuffle.each do |document_id|
        doc = Document.find(document_id)
        doc.update_attribute(:test_index, i)
        doc.update_attribute(:name, i.to_s.rjust(4, '0') + ' - ' + doc.name)
        zip.put_next_entry("#{doc.name}.xml")
        zip << doc.qrda
        i += 1
      end
    end
  end

  def update_qrda_progress
    @current_document += 1
    update_attribute(:qrda_progress, 100 * @current_document / @documents_to_generate)
  end

  def determine_useful_measures(validation_id)
    validation = Validation.find(validation_id)
    if validation.measure_type == 'discrete'
      measure_ids.select { |id| HealthDataStandards::CQM::Measure.find_by(_id: id).continuous_variable == false }
    elsif validation.measure_type == 'continuous'
      measure_ids.select { |id| HealthDataStandards::CQM::Measure.find_by(_id: id).continuous_variable == true }
    else
      measure_ids
    end
  end
end
